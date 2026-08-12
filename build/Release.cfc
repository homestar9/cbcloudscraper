/**
 * Checks, builds, and publishes a project release.
 *
 * Run `box run-script release` from the project root. The task checks the repository first.
 * It then syncs the production branch, builds the package, publishes to ForgeBox when enabled,
 * creates a Git tag, and creates a GitHub Release when enabled.
 *
 * All checks run before the first permanent publishing step. If a later step fails, the task
 * prints the commands needed to finish the same release.
 * Use `release:dryrun` to build and check without publishing, tagging, or pushing.
 */
component {

	/** Load shared settings and the changelog parser. */
	function init(){
		variables.config           = new BuildConfig( getDirectoryFromPath( getCurrentTemplatePath() ) );
		variables.settings         = variables.config.getSettings();
		variables.changelogService = new lib.ChangelogService();
		return this;
	}

	/**
	 * Run the complete release workflow in the required order.
	 *
	 * @version     The version to release. Defaults to the box.json version.
	 * @dryRun      Run checks and build files without publishing, tagging, or pushing. Print each
	 *              command that would run.
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

		// Run all checks before making any permanent remote changes.
		preflight(
			version     = releaseVersion,
			dryRun     = arguments.dryRun,
			existingTag = arguments.existingTag
		);

		// Fast-forward a branch-based release to its remote branch. A dry run changes nothing.
		// A tag-based release must build the exact commit that is already checked out.
		if ( variables.settings.gitSync && !arguments.dryRun && !arguments.existingTag ) {
			syncWithRemote();
		} else if ( arguments.existingTag ) {
			print.greenLine( "Using existing tag #tagName# at the checked-out commit; skipping branch sync." ).toConsole();
		} else if ( variables.settings.gitSync ) {
			print.yellowLine( "Dry run: skipping git pull." ).toConsole();
		}

		// Build the package and stop the release if the test suite or package checks fail.
		runBuild( releaseVersion, arguments.skipTests, arguments.buildID );

		// Publish the checked build directory to ForgeBox when that target is enabled.
		if ( variables.settings.publish.forgebox ) {
			publishToForgebox( releaseVersion, arguments.dryRun );
		} else {
			print.line().yellowLine( "Skipping ForgeBox (publish.forgebox is false in build.json)." ).toConsole();
		}

		// Create and push the tag, then create the GitHub Release.
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
	 * Run every check that must pass before the release changes a remote system.
	 *
	 * @version     The version being released.
	 * @dryRun      Skip checks that only matter when remote systems will change.
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

	// Checks before publishing

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
	 * Tag the release, push the tag, and create a GitHub Release. Use the changelog section as the
	 * release notes and attach the built ZIP.
	 *
	 * Call this method by itself to finish a release that stopped after ForgeBox publishing.
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

	// GitHub Release steps

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

		// Give the notes to the GitHub CLI as a file so their Markdown formatting stays unchanged.
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

	// Other release helpers

	/**
	 * Confirm that an existing lightweight or annotated tag points to the checked-out commit.
	 * The full release and standalone GitHub target both call this method. This prevents either
	 * path from attaching build files created from a different commit.
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
	 * Run Build.cfc and stop the release if the build fails.
	 *
	 * Start Build.cfc as a CommandBox task instead of creating the component directly. CommandBox
	 * gives task instances helpers such as command() and print. A regular component instance would
	 * not receive those helpers.
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
	 * Fast-forward the checked-out production branch to include remote commits without creating a
	 * merge commit. Earlier checks already confirmed the branch name and clean working tree.
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
	 * Publish the checked build directory instead of the project root.
	 *
	 * Publishing from the project root uses .gitignore rules. A broad ignore rule could remove
	 * required source directories. Publishing the build directory sends the exact files that the
	 * build already checked.
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

		// Save the current directory so a failed publish cannot leave CommandBox in the staging directory.
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
	 * Stop after a failure that may happen after publishing. Print the exact commands needed to
	 * finish the release. Starting the full release again would fail because the version may
	 * already be published.
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
	 * Print several lines of help, then stop the task with one error line.
	 *
	 * CommandBox removes line breaks from error() messages. Print the detailed help first so its
	 * line breaks remain readable. Then pass only the summary to error(), which ends the task.
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

	/** Read one version's release notes from the configured changelog. */
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
	 * Return true for a prerelease version such as 1.0.0-beta.4. GitHub uses this value to mark
	 * the release as a prerelease.
	 *
	 * @version The version being released.
	 */
	private boolean function isPrerelease( required string version ){
		return find( "-", arguments.version ) > 0;
	}
}
