/**
 * Reports whether the project is ready for a release.
 *
 * Run `box run-script release:check` from the project root. The task checks the settings,
 * repository, changelog, required tools, and test server. It reports every problem it can find
 * instead of stopping after the first problem.
 *
 * This task does not change files, Git state, servers, or remote services.
 */
component {

	/** Loads settings while keeping configuration errors for the final report. */
	function init(){
		variables.configError = "";
		try {
			variables.config = new BuildConfig( getDirectoryFromPath( getCurrentTemplatePath() ) );
			variables.settings      = variables.config.getSettings();
		} catch ( any exception ) {
			variables.configError = exception.message;
		}
		return this;
	}

	/**
	 * Runs every check and prints a summary.
	 */
	function run(){
		print.line().boldLine( "Release readiness" ).line( repeatString( "-", 60 ) ).toConsole();

		if ( len( variables.configError ) ) {
			report( false, "build.json", variables.configError, "Fix build/build.json, then run this again." );
			print.line().boldRedLine( "Cannot check anything else until the settings load." ).toConsole();
			return error( "Settings could not be read." );
		}

		variables.problems = 0;

		checkConfig();
		checkGit();
		checkChangelog();
		checkTools();
		checkServer();

		print.line( repeatString( "-", 60 ) ).toConsole();
		if ( variables.problems == 0 ) {
			print
				.boldGreenLine( "Everything looks ready." )
				.line( "Next: box run-script release:dryrun to rehearse without publishing." )
				.toConsole();
		} else {
			print
				.boldYellowLine( "#variables.problems# thing#( variables.problems == 1 ? "" : "s" )# to sort out before releasing." )
				.toConsole();
		}
	}

	// READINESS CHECKS

	/**
	 * Reports the settings a release will use, so surprises show up here rather than mid
	 * release.
	 */
	private function checkConfig(){
		print.line().boldLine( "Settings" ).toConsole();
		report( true, "build.json", "loaded" );
		var publishSummary = "ForgeBox=#yesNo( variables.settings.publish.forgebox )#  "
			& "GitHub=#yesNo( variables.settings.publish.github )#";
		print
			.line( "        project:   #variables.config.slug()# #variables.config.version()# (#variables.settings.projectType#)" )
			.line( "        branch:    #variables.settings.branch#" )
			.line( "        publish:   #publishSummary#" )
			.line( "        tests:     #( variables.settings.runTests ? "run during build" : "OFF in build.json" )#" )
			.toConsole();
	}

	/**
	 * Checks Git first. The remaining Git checks only run when the folder is a repository.
	 */
	private function checkGit(){
		print.line().boldLine( "Git" ).toConsole();

		var status = variables.config.execNative( "git", [ "status", "--porcelain" ] );
		if ( status.exitCode == 127 ) {
			report(
				false,
				"git",
				"not found",
				"Install git. If you just installed it, open a new terminal so it is picked up."
			);
			return;
		}
		if ( status.exitCode != 0 ) {
			report( false, "git", "not a repository", "Run this from inside your project's git repository." );
			return;
		}
		report( true, "git", "found at " & variables.config.findBinary( "git" ) );
		checkWorkingTree( status );
		checkReleaseBranch();
		checkVersionTag();
		checkRemote();
	}

	private void function checkWorkingTree( required struct status ){
		if ( len( trim( status.output ) ) ) {
			var changed = listLen( status.output, chr( 10 ) );
			report(
				false,
				"clean checkout",
				"#changed# uncommitted change#( changed == 1 ? "" : "s" )#",
				"Run git status, stage the intended files with git add, then commit them; a release refuses to start otherwise."
			);
		} else {
			report( true, "clean checkout", "nothing uncommitted" );
		}
	}

	private void function checkReleaseBranch(){
		var branch = trim( variables.config.execNative( "git", [ "rev-parse", "--abbrev-ref", "HEAD" ] ).output );
		if ( branch != variables.settings.branch ) {
			report(
				false,
				"branch",
				"on #branch#, releases come from production branch #variables.settings.branch#",
				"Switch with: git switch #variables.settings.branch#   (or correct ""branch"" in build/build.json)"
			);
		} else {
			report( true, "branch", branch );
		}
	}

	private void function checkVersionTag(){
		var tagName = variables.settings.tagPrefix & variables.config.version();
		var tagged  = variables.config.execNative( "git", [ "rev-parse", "-q", "--verify", "refs/tags/" & tagName ] );
		if ( tagged.exitCode == 0 ) {
			report(
				false,
				"version",
				"#tagName# is already released",
				"Raise the version first: box run-script bump:patch"
			);
		} else {
			report( true, "version", "#tagName# has not been released" );
		}
	}

	private void function checkRemote(){
		var remote = variables.config.execNative( "git", [ "ls-remote", "--exit-code", "origin", "HEAD" ] );
		if ( remote.exitCode != 0 ) {
			var fix = remote.output contains "publickey"
				? "Your SSH key is not accepted. Add it at https://github.com/settings/ssh/new, "
					& "or switch to HTTPS: git remote set-url origin "
					& "https://github.com/<you>/<repo>.git && gh auth setup-git"
				: "Check the remote and your access: git remote -v";
			report( false, "remote", "cannot reach origin", fix );
		} else {
			report( true, "remote", "origin reachable" );
		}
	}

	/**
	 * Checks the changelog exists and holds what a release needs.
	 */
	private function checkChangelog(){
		print.line().boldLine( "Changelog" ).toConsole();

		var path = variables.config.repoPath( variables.settings.changelog );
		if ( !fileExists( path ) ) {
			report(
				false,
				variables.settings.changelog,
				"missing",
				"Create it: box task run taskFile=build/Install.cfc"
			);
			return;
		}

		var body    = fileRead( path );
		var version = variables.config.version();

		// A doubled ## in a CFML string means one literal #, so #### matches a "## " heading.
		if ( !reFindNoCase( "####\s*\[Unreleased\]", body ) ) {
			report(
				false,
				"[Unreleased]",
				"no [Unreleased] section",
				"Add a ""#### [Unreleased]"" heading and write new notes under it."
			);
		} else {
			report( true, "[Unreleased]", "present" );
		}

		if ( body contains "[#version#]" ) {
			report( true, "notes for #version#", "found" );
		} else {
			report(
				false,
				"notes for #version#",
				"no ""#### [#version#]"" section",
				variables.settings.publish.github
					? "Run: box run-script bump:patch  (moves [Unreleased] into a dated section)"
					: "Only needed for a GitHub Release, which is off in build.json."
			);
		}
	}

	/**
	 * Checks only the publishing tools enabled in build.json.
	 */
	private function checkTools(){
		print.line().boldLine( "Tools" ).toConsole();
		checkGitHubCli();
		checkForgeBoxLogin();
	}

	private void function checkGitHubCli(){
		if ( variables.settings.publish.github ) {
			if ( !variables.config.commandExists( "gh" ) ) {
				report(
					false,
					"GitHub CLI",
					"not found",
					"Install from https://cli.github.com then run: gh auth login. If you just installed it, open a new terminal."
				);
			} else {
				var auth = variables.config.execNative( "gh", [ "auth", "status" ] );
				if ( auth.exitCode != 0 ) {
					report( false, "GitHub CLI", "not signed in", "Run: gh auth login" );
				} else {
					report( true, "GitHub CLI", "signed in" );
				}
			}
		} else {
			report( true, "GitHub CLI", "not needed (publish.github is false)" );
		}
	}

	private void function checkForgeBoxLogin(){
		if ( variables.settings.publish.forgebox ) {
			var forgeBoxUser = "";
			try {
				forgeBoxUser = trim( command( "forgebox whoami" ).run( returnOutput = true ) );
			} catch ( any ignoredException ) {
				forgeBoxUser = "";
			}
			if ( !len( forgeBoxUser ) || forgeBoxUser contains "not logged in" ) {
				report( false, "ForgeBox", "not signed in", "Run: box forgebox login" );
			} else {
				report( true, "ForgeBox", "signed in" );
			}
		} else {
			report( true, "ForgeBox", "not needed (publish.forgebox is false)" );
		}
	}

	/**
	 * Checks the test server is answering, since the build runs the suite against it.
	 */
	private function checkServer(){
		print.line().boldLine( "Test server" ).toConsole();

		if ( !variables.settings.runTests ) {
			report( true, "test server", "not needed (runTests is false)" );
			return;
		}

		var probeUrl   = variables.config.probeUrl();
		var httpResult = "";
		try {
			cfhttp(
				url          = probeUrl,
				method       = "GET",
				timeout      = 15,
				throwonerror = false,
				redirect     = false,
				result       = "local.httpResult"
			);
		} catch ( any ignoredException ) {
			httpResult = { statuscode : "0" };
		}
		var statusCode = val( httpResult.statuscode ?: "0" );

		if ( statusCode >= 200 && statusCode < 400 ) {
			report( true, "test server", "answering at #probeUrl# (status #statusCode#)" );
		} else {
			report(
				false,
				"test server",
				"no answer at #probeUrl#",
				"Start a server first, for example: box run-script start:2023  (or set runTests false in build/build.json)"
			);
		}
	}

	// REPORT OUTPUT

	/**
	 * Prints one result and counts the failures.
	 *
	 * @passed  Whether the check passed.
	 * @label   What was checked.
	 * @detail  What was found.
	 * @fix     What to do about it, shown only on a failure.
	 */
	private function report( required boolean passed, required string label, string detail = "", string fix = "" ){
		if ( arguments.passed ) {
			print.greenLine( "  ok    #arguments.label#: #arguments.detail#" ).toConsole();
			return;
		}
		variables.problems = ( variables.problems ?: 0 ) + 1;
		print.boldRedLine( "  FIX   #arguments.label#: #arguments.detail#" ).toConsole();
		if ( len( arguments.fix ) ) {
			print.yellowLine( "        -> #arguments.fix#" ).toConsole();
		}
	}

	/**
	 * Turns true and false into yes and no for reading.
	 *
	 * @value The value to show.
	 */
	private string function yesNo( required boolean value ){
		return arguments.value ? "yes" : "no";
	}
}
