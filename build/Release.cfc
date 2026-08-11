/**
 * Checks, builds, and publishes one project release.
 *
 * Run `box run-script release` from the project root. The task checks the repository first.
 * It then syncs the production branch, builds the package, publishes to ForgeBox when enabled,
 * creates a Git tag, and creates a GitHub Release when enabled.
 *
 * The order protects the release. Every safe check runs before the first permanent publish.
 * If a later step fails, the task prints the commands needed to finish the same release.
 * Use `release:dryrun` to build and check without publishing, tagging, or pushing.
 */
component {

	/** Loads shared settings and the changelog parser. */
	function init(){
		variables.config           = new BuildConfig( getDirectoryFromPath( getCurrentTemplatePath() ) );
		variables.settings         = variables.config.getSettings();
		variables.changelogService = new lib.ChangelogService();
		return this;
	}

	/**
	 * Runs the complete release workflow in its required order.
	 *
	 * @version     The version to release. Defaults to the box.json version.
	 * @dryRun      Do everything except publish, tag, and push. Prints what it would have run.
	 *              Use this for your first release, or to test a change to the build.
	 * @skipTests   Skip the test suite. Use only when the current version has already been tested.
	 * @existingTag Publish a tag that already exists and points at HEAD. Used by tag-triggered CI.
	 * @buildID      Optional build identifier passed through to Build.cfc. CI uses its run number.
	 */
	function run(
		string version      = "",
		boolean dryRun      = false,
		boolean skipTests   = false,
		boolean existingTag = false,
		string buildID      = ""
	){
		var releaseVersion = len( trim( arguments.version ) ) ? trim( arguments.version ) : variables.config.version();
		var tagName        = variables.settings.tagPrefix & releaseVersion;

		if ( arguments.dryRun ) {
			print
				.line()
				.boldYellowLine( "DRY RUN: nothing will be published, tagged, or pushed." )
				.line()
				.toConsole();
		}

		// 1. Checks. These run first so nothing permanent has happened if one fails.
		preflight(
			version     = releaseVersion,
			dryRun     = arguments.dryRun,
			existingTag = arguments.existingTag
		);

		// 2. Line up a branch-based release with the remote. A dry run changes nothing, and a
		//    tag-triggered release must build the immutable commit that is already checked out.
		if ( variables.settings.gitSync && !arguments.dryRun && !arguments.existingTag ) {
			syncWithRemote();
		} else if ( arguments.existingTag ) {
			print.greenLine( "Using existing tag #tagName# at the checked-out commit; skipping branch sync." ).toConsole();
		} else if ( variables.settings.gitSync ) {
			print.yellowLine( "Dry run: skipping git pull." ).toConsole();
		}

		// 3. Build. The suite runs here and stops the release if anything fails.
		runBuild( releaseVersion, arguments.skipTests, arguments.buildID );

		// 4. Publish to ForgeBox, from the built folder rather than the project root.
		if ( variables.settings.publish.forgebox ) {
			publishToForgebox( releaseVersion, arguments.dryRun );
		} else {
			print.line().yellowLine( "Skipping ForgeBox (publish.forgebox is false in build.json)." ).toConsole();
		}

		// 5. Tag and create the GitHub Release.
		if ( variables.settings.publish.github ) {
			github(
				version     = releaseVersion,
				dryRun     = arguments.dryRun,
				existingTag = arguments.existingTag
			);
		} else {
			print.yellowLine( "Skipping GitHub (publish.github is false in build.json)." ).toConsole();
		}

		print.line().toConsole();
		if ( arguments.dryRun ) {
			print
				.boldGreenLine( "Dry run finished. Nothing was published." )
				.line( "The package was built and checked. Run box run-script release when you are ready." )
				.toConsole();
		} else {
			print.boldGreenLine( "Released #tagName#." ).toConsole();
		}
	}

	/**
	 * Runs every check that must pass before the release can change remote systems.
	 *
	 * @version     The version being released.
	 * @dryRun      Soften the checks that only matter for a real release.
	 * @existingTag Require the expected tag at HEAD instead of requiring an untagged release branch.
	 */
	function preflight( string version = "", boolean dryRun = false, boolean existingTag = false ){
		var releaseVersion = len( trim( arguments.version ) ) ? trim( arguments.version ) : variables.config.version();

		print.boldBlueLine( "=== Checking ===" ).toConsole();
		var repositoryStatus = checkRepository();
		checkWorkingTree( repositoryStatus, arguments.dryRun );
		var branchName = checkReleaseBranch( arguments.existingTag, arguments.dryRun );

		var tagName = variables.settings.tagPrefix & releaseVersion;
		checkVersionTag( tagName, arguments.existingTag );
		checkReleaseChangelog( releaseVersion );
		checkGitHubCli( arguments.dryRun );

		printPreflightSummary( branchName, releaseVersion, tagName, arguments.dryRun, arguments.existingTag );
	}

	// PREFLIGHT CHECKS

	private struct function checkRepository(){
		var status = variables.config.execNative( "git", [ "status", "--porcelain" ] );
		if ( status.exitCode == 127 ) {
			return error( "Could not find git. Install it, or open a new terminal if you installed it recently." );
		}
		if ( status.exitCode != 0 ) {
			return error( "git could not read this folder (#status.output#). Is it a git repository?" );
		}
		return status;
	}

	private void function checkWorkingTree( required struct status, required boolean dryRun ){
		if ( variables.settings.requireCleanTree && len( trim( status.output ) ) ) {
			if ( arguments.dryRun ) {
				print
					.yellowLine( "  note  you have uncommitted changes; a real release would stop here" )
					.toConsole();
			} else {
				return fail(
					"You have uncommitted changes. Commit or stash them, then run this again.",
					listToArray( status.output, chr( 10 ) ),
					"Uncommitted"
				);
			}
		}
	}

	private string function checkReleaseBranch( required boolean existingTag, required boolean dryRun ){
		var branch = variables.config.execNative( "git", [ "rev-parse", "--abbrev-ref", "HEAD" ] );
		if ( branch.exitCode != 0 ) {
			return error( "git could not identify the checked-out branch (#branch.output#)." );
		}
		var branchName = trim( branch.output );
		if ( arguments.existingTag && branchName != variables.settings.branch && branchName != "HEAD" ) {
			return error(
				"Existing-tag releases run from production branch #variables.settings.branch# or a detached tag checkout, "
				& "but you are on #branchName#."
			);
		} else if ( !arguments.existingTag && branchName != variables.settings.branch && arguments.dryRun ) {
			print
				.boldYellowLine( "  warning  rehearsing from #branchName#, not production branch #variables.settings.branch#" )
				.yellowLine( "           A real release still has to run from #variables.settings.branch#." )
				.toConsole();
		} else if ( !arguments.existingTag && branchName != variables.settings.branch ) {
			return error(
				"Releases come from the production branch #variables.settings.branch#, but you are on #branchName#. "
				& "Switch branch, or change ""branch"" in build/build.json."
			);
		}
		return branchName;
	}

	private void function checkVersionTag( required string tagName, required boolean existingTag ){
		if ( arguments.existingTag ) {
			requireExistingTagAtHead( arguments.tagName );
		} else {
			var tagCheck = variables.config.execNative( "git", [ "rev-parse", "-q", "--verify", "refs/tags/" & arguments.tagName ] );
			if ( tagCheck.exitCode == 0 ) {
				var tagCommit  = variables.config.execNative( "git", [ "rev-list", "-n", "1", "refs/tags/" & arguments.tagName ] );
				var headCommit = variables.config.execNative( "git", [ "rev-parse", "HEAD" ] );
				if (
					tagCommit.exitCode == 0
						&& headCommit.exitCode == 0
						&& trim( tagCommit.output ) == trim( headCommit.output )
				) {
					return error(
						"Tag #arguments.tagName# already exists at this commit. If Gitflow or GitKraken created it "
						& "intentionally, publish it with: box run-script release:existing-tag"
					);
				}
				return error(
					"Tag #arguments.tagName# already exists locally at a different commit. Do not move a published tag. "
					& "Verify the tag and release history, or choose a new version."
				);
			}
			var remoteTag = variables.config.execNative(
				"git",
				[ "ls-remote", "--exit-code", "--tags", "origin", "refs/tags/" & arguments.tagName ]
			);
			if ( remoteTag.exitCode == 0 ) {
				return error(
					"Tag #arguments.tagName# already exists on origin. Fetch tags first. If a Gitflow tool created it "
					& "for this release, run box run-script release:existing-tag from its tagged production "
					& "commit; otherwise the version is already claimed."
				);
			}
			if ( remoteTag.exitCode != 2 ) {
				return error( "Could not check origin for tag #arguments.tagName# (#remoteTag.output#). Nothing has been published." );
			}
		}
	}

	private void function checkReleaseChangelog( required string releaseVersion ){
		if ( variables.settings.publish.github ) {
			extractChangelogSection( arguments.releaseVersion );
		}
	}

	private void function checkGitHubCli( required boolean dryRun ){
		if ( variables.settings.publish.github && !arguments.dryRun ) {
			var ghCheck = variables.config.execNative( "gh", [ "auth", "status" ] );
			if ( ghCheck.exitCode == 127 ) {
				return fail(
					"Could not find the GitHub CLI (gh).",
					[
						"Install it from https://cli.github.com, then run: gh auth login",
						"",
						"If you have just installed it, open a new terminal. A terminal keeps the",
						"PATH it started with, so a tool added afterwards looks missing until then."
					]
				);
			}
			if ( ghCheck.exitCode != 0 ) {
				return fail(
					"The GitHub CLI is not signed in, so stopping before anything is published.",
					[ "gh auth login", "", "What gh said: " & ghCheck.output ]
				);
			}
		}
	}

	private void function printPreflightSummary(
		required string branchName,
		required string releaseVersion,
		required string tagName,
		required boolean dryRun,
		required boolean existingTag
	){
		print
			.greenLine(
				arguments.existingTag
					? "  ok  existing tag #arguments.tagName# points to this commit"
					: "  ok  clean checkout#( arguments.branchName == variables.settings.branch ? " on " & variables.settings.branch : "" )#"
			)
			.greenLine( arguments.existingTag ? "  ok  existing-tag publish mode" : "  ok  #arguments.releaseVersion# has not been released" )
			.greenLine( variables.settings.publish.github ? "  ok  changelog entry found" : "  --  changelog not needed" )
			.greenLine( variables.settings.publish.github && !arguments.dryRun ? "  ok  GitHub CLI ready" : "  --  GitHub CLI not needed" )
			.toConsole();
	}

	/**
	 * Tags the release, pushes it, and creates the GitHub Release with the changelog notes and
	 * the built zip attached.
	 *
	 * Run on its own to finish a release that stopped after publishing.
	 *
	 * @version     The version being released.
	 * @notesOnly   Print the release notes and stop. Nothing is tagged or pushed.
	 * @dryRun      Print what would run without doing it.
	 * @existingTag The expected tag already exists, so only create the GitHub Release.
	 */
	function github(
		string version      = "",
		boolean notesOnly   = false,
		boolean dryRun      = false,
		boolean existingTag = false
	){
		var releaseVersion = len( trim( arguments.version ) ) ? trim( arguments.version ) : variables.config.version();
		var tagName        = variables.settings.tagPrefix & releaseVersion;
		if ( arguments.existingTag ) {
			requireExistingTagAtHead( tagName );
		}

		var notes = extractChangelogSection( releaseVersion );
		if ( arguments.notesOnly ) {
			print.line().boldLine( "Release notes for #tagName#:" ).line( notes ).toConsole();
			return;
		}

		var ghArgs = buildGitHubArguments( releaseVersion, tagName, notes );

		if ( arguments.dryRun ) {
			return printGitHubDryRun( tagName, ghArgs, notes, arguments.existingTag );
		}

		return publishGitHubRelease( tagName, ghArgs, arguments.existingTag );
	}

	// GITHUB RELEASE STEPS

	private array function buildGitHubArguments(
		required string releaseVersion,
		required string tagName,
		required string notes
	){
		var projectSlug = variables.config.slug();
		var zipPath = variables.config.repoPath(
			"#variables.settings.artifactsDir#/#projectSlug#/#arguments.releaseVersion#/#projectSlug#-#arguments.releaseVersion#.zip"
		);
		if ( !fileExists( zipPath ) ) {
			return error( "No built zip at #zipPath#. Build it first: box run-script build:package" );
		}

		// The GitHub CLI reads the notes from a file so their Markdown stays unchanged.
		var notesFile = variables.config.repoPath( "#variables.settings.stagingDir#/release-notes.md" );
		if ( !directoryExists( getDirectoryFromPath( notesFile ) ) ) {
			directoryCreate( getDirectoryFromPath( notesFile ), true, true );
		}
		fileWrite( notesFile, arguments.notes );

		var ghArgs = [ "release", "create", arguments.tagName, "--title", arguments.tagName, "--notes-file", notesFile ];
		if ( isPrerelease( arguments.releaseVersion ) ) {
			ghArgs.append( "--prerelease" );
		}
		ghArgs.append( zipPath );

		var shaPath = zipPath & ".sha512";
		if ( fileExists( shaPath ) ) {
			ghArgs.append( shaPath );
		}
		return ghArgs;
	}

	private void function printGitHubDryRun(
		required string tagName,
		required array ghArgs,
		required string notes,
		required boolean existingTag
	){
		var preview = print.line().boldYellowLine( "Dry run, would now run:" );
		if ( !arguments.existingTag ) {
			preview
				.line( "  git tag #arguments.tagName#" )
				.line( "  git push origin #variables.settings.branch#" )
				.line( "  git push origin #arguments.tagName#" );
		}
		preview
			.line( "  gh " & arrayToList( arguments.ghArgs, " " ) )
			.line()
			.boldLine( "Release notes it would use:" )
			.line( arguments.notes )
			.toConsole();
	}

	private void function publishGitHubRelease(
		required string tagName,
		required array ghArgs,
		required boolean existingTag
	){
		print.line().boldBlueLine( "=== Tagging and releasing on GitHub ===" ).toConsole();

		var result = { exitCode : 0, output : "" };
		if ( !arguments.existingTag ) {
			result = variables.config.execNative( "git", [ "tag", arguments.tagName ] );
			if ( result.exitCode != 0 ) {
				return error( "Could not create tag #arguments.tagName#: #result.output#" );
			}

			result = variables.config.execNative( "git", [ "push", "origin", variables.settings.branch ] );
			if ( result.exitCode != 0 ) {
				return failWithManualSteps( "The push failed (#result.output#).", arguments.tagName, arguments.ghArgs );
			}

			result = variables.config.execNative( "git", [ "push", "origin", arguments.tagName ] );
			if ( result.exitCode != 0 ) {
				return failWithManualSteps( "Pushing the tag failed (#result.output#).", arguments.tagName, arguments.ghArgs );
			}
		}

		result = variables.config.execNative( "gh", arguments.ghArgs );
		if ( result.exitCode != 0 ) {
			return fail(
				"Creating the GitHub Release failed (#result.output#). The tag is already pushed.",
				[ "gh " & arrayToList( arguments.ghArgs, " " ) ],
				"Run this to finish"
			);
		}

		print
			.greenLine(
				arguments.existingTag
					? "Created the GitHub Release for existing tag #arguments.tagName#."
					: "Tagged #arguments.tagName# and created the GitHub Release."
			)
			.toConsole();
	}

	// OTHER RELEASE HELPERS

	/**
	 * Proves an existing lightweight or annotated tag resolves to the checked-out commit. This
	 * is called by both the full release and the standalone github target, so recovery commands
	 * cannot accidentally attach artifacts from a different commit.
	 *
	 * @tagName The complete tag name, including its configured prefix.
	 */
	private function requireExistingTagAtHead( required string tagName ){
		var tagCheck = variables.config.execNative( "git", [ "rev-parse", "-q", "--verify", "refs/tags/" & arguments.tagName ] );
		if ( tagCheck.exitCode != 0 ) {
			return error( "Existing-tag mode expected #arguments.tagName#, but that tag is not available in this checkout." );
		}

		var tagCommit  = variables.config.execNative( "git", [ "rev-list", "-n", "1", "refs/tags/" & arguments.tagName ] );
		var headCommit = variables.config.execNative( "git", [ "rev-parse", "HEAD" ] );
		if (
			tagCommit.exitCode != 0
				|| headCommit.exitCode != 0
				|| trim( tagCommit.output ) != trim( headCommit.output )
		) {
			return error( "Tag #arguments.tagName# does not point at the checked-out commit. Refusing to publish the wrong source." );
		}
	}

	/**
	 * Runs Build.cfc and stops the release if the build fails.
	 *
	 * It starts Build.cfc as its own task rather than creating it directly. CommandBox hands a
	 * task the helpers it needs, such as command() and print, and a component created the
	 * ordinary way does not get them.
	 *
	 * @version   The version being built.
	 * @skipTests Skip the test suite.
	 * @buildID   Optional build identifier to pass through to Build.cfc.
	 */
	private function runBuild( required string version, boolean skipTests = false, string buildID = "" ){
		print.line().boldBlueLine( "=== Building ===" ).toConsole();

		var buildFailed = false;
		try {
			command( "task run" )
				.params(
					taskFile     = variables.config.buildPath( "Build.cfc" ),
					target       = "run",
					":version"   = arguments.version,
					":skipTests" = arguments.skipTests,
					":buildID"   = arguments.buildID
				)
				.run();
			buildFailed = ( shell.getExitCode() != 0 );
		} catch ( any exception ) {
			buildFailed = true;
			print.redLine( exception.message ).toConsole();
		}

		if ( buildFailed ) {
			return error( "Stopping: the build failed, so nothing was published." );
		}
	}

	/**
	 * Fast-forwards the checked-out production branch, so the release includes remote work but
	 * never creates an accidental merge commit during publishing. Preflight has already proved
	 * this is the configured branch and nothing is uncommitted.
	 */
	private function syncWithRemote(){
		print.line().boldBlueLine( "=== Lining up with the remote ===" ).toConsole();

		var result = variables.config.execNative( "git", [ "pull", "--ff-only", "origin", variables.settings.branch ] );
		if ( result.exitCode != 0 ) {
			var guidance = [ result.output ];
			if ( result.output contains "publickey" ) {
				guidance.append( "" );
				guidance.append( "git cannot sign in to your remote. Either add your SSH key at" );
				guidance.append( "https://github.com/settings/ssh/new, or switch the remote to HTTPS:" );
				guidance.append( "" );
				guidance.append( "  git remote set-url origin https://github.com/<you>/<repo>.git" );
				guidance.append( "  gh auth setup-git" );
			}
			return fail( "git pull failed.", guidance, "What git said" );
		}
		print.greenLine( "Up to date with origin/#variables.settings.branch#." ).toConsole();
	}

	/**
	 * Publishes from the built folder rather than the project root.
	 *
	 * This matters. Publishing from the project root packages using .gitignore, and one broad
	 * ignore rule can quietly drop source folders from what people install. Publishing the
	 * folder the build produced sends exactly what the build checked.
	 *
	 * @version The version being published.
	 * @dryRun  Print what would run without doing it.
	 */
	private function publishToForgebox( required string version, boolean dryRun = false ){
		var slug       = variables.config.slug();
		var publishDir = variables.config.repoPath( "#variables.settings.stagingDir#/#slug#" );

		if ( arguments.dryRun ) {
			print
				.line()
				.boldYellowLine( "Dry run, would now publish to ForgeBox:" )
				.line( "  cd #publishDir#" )
				.line( "  publish" )
				.toConsole();
			return;
		}

		if ( !directoryExists( publishDir ) ) {
			return error( "No built folder at #publishDir#. The build should have created it." );
		}

		print.line().boldBlueLine( "=== Publishing to ForgeBox ===" ).toConsole();

		// Remember where we were, so a failed publish cannot leave the shell inside the
		// staging folder.
		var originalDir = shell.pwd();
		try {
			command( "cd" ).params( publishDir ).run();
			command( "publish" ).run();
			if ( shell.getExitCode() != 0 ) {
				return error( "Publishing to ForgeBox failed. Check you are signed in: box forgebox whoami" );
			}
		} finally {
			command( "cd" ).params( originalDir ).run();
		}

		print.greenLine( "Published #slug# #arguments.version# to ForgeBox." ).toConsole();
	}

	/**
	 * Stops the release after the package may already be published, printing the exact commands
	 * that finish the job. Running the release again would refuse, because the version is out.
	 *
	 * @reason  What failed.
	 * @tagName The tag for this release.
	 * @ghArgs  The arguments for the gh release command.
	 */
	private function failWithManualSteps( required string reason, required string tagName, required array ghArgs ){
		return fail(
			arguments.reason & " The package may already be published, so finish by hand rather than running the release again.",
			[
				"git push origin " & variables.settings.branch,
				"git push origin " & arguments.tagName,
				"gh " & arrayToList( arguments.ghArgs, " " )
			],
			"Run these to finish"
		);
	}

	/**
	 * Stops the task, printing guidance that spans several lines.
	 *
	 * CommandBox's error() removes line breaks from its message, so anything longer than a
	 * sentence arrives as one run-together block. The guidance is printed first, where it keeps
	 * its shape, and error() is left with the single line that says what went wrong. That is
	 * also why the guidance appears above the error rather than below it: error() ends the task.
	 *
	 * @summary One line saying what went wrong.
	 * @detail  Lines of guidance to print first.
	 * @heading A short label for the guidance.
	 */
	private function fail( required string summary, array detail = [], string heading = "What to do" ){
		if ( arrayLen( arguments.detail ) ) {
			print.line().boldLine( arguments.heading & ":" ).toConsole();
			for ( var line in arguments.detail ) {
				print.yellowLine( "  " & line ).toConsole();
			}
			print.line().toConsole();
		}
		return error( arguments.summary );
	}

	/** Reads one version's release notes from the configured changelog. */
	private string function extractChangelogSection( required string version ){
		var changelogPath = variables.config.repoPath( variables.settings.changelog );
		if ( !fileExists( changelogPath ) ) {
			return error( "No #variables.settings.changelog# in the project root. Create one before releasing." );
		}

		try {
			return variables.changelogService.extractReleaseNotes(
				content       = fileRead( changelogPath ),
				version       = arguments.version,
				changelogName = variables.settings.changelog
			);
		} catch ( any exception ) {
			return error( exception.message );
		}
	}

	/**
	 * A version with a hyphen, such as 1.0.0-beta.4, is a pre-release, so the GitHub Release
	 * is marked as one.
	 *
	 * @version The version being released.
	 */
	private boolean function isPrerelease( required string version ){
		return find( "-", arguments.version ) > 0;
	}
}
