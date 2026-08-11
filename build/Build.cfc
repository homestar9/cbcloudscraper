/**
 * Builds and checks the package that can be published.
 *
 * Run `box run-script build:package` from the project root. The task runs the tests, copies
 * allowed source files into a clean staging folder, replaces version tokens, creates a ZIP,
 * verifies the ZIP, and writes checksum files.
 *
 * Build files are written under .artifacts/<slug>/<version>/. Use `:skipTests=true` only when
 * the same source has already passed its tests. Project settings come from build/build.json.
 */
component {

	/** Loads the settings and prepares empty staging and artifact folders. */
	function init(){
		variables.config = new BuildConfig( getDirectoryFromPath( getCurrentTemplatePath() ) );
		variables.settings = variables.config.getSettings();
		variables.root   = variables.config.getRoot();

		variables.buildDir     = variables.root & "/" & variables.settings.stagingDir;
		variables.artifactsDir = variables.root & "/" & variables.settings.artifactsDir;

		prepareOutputDirectories();
		configureColdBoxMapping();

		return this;
	}

	/**
	 * Runs the tests, builds the package, and writes checksums.
	 *
	 * @projectName The name used for the package folder and zip. Defaults to the box.json slug.
	 * @version     The version being built. Defaults to the box.json version.
	 * @buildID     The build identifier. When blank, uses the short git commit hash.
	 * @branch      The branch being built. When blank, reads the current branch.
	 * @skipTests   Skip the test suite for this run only. Use only when this version has already
	 *              been tested. It prints a warning, because an untested build is a real risk.
	 */
	function run(
		string projectName = "",
		string version     = "",
		string buildID     = "",
		string branch      = "",
		boolean skipTests  = false
	){
		fillDefaults( arguments );

		if ( arguments.skipTests || !variables.settings.runTests ) {
			var reason = arguments.skipTests ? "requested with skipTests" : "disabled in build.json";
			print
				.line()
				.boldYellowLine( "WARNING: the test suite was skipped (#reason#)." )
				.yellowLine( "This package has not been tested by this build." )
				.line()
				.toConsole();
		} else {
			ensureTestRunnerReachable();
			runTests();
		}

		// Map the project so a build can load the project's own components if it needs to.
		fileSystemUtil.createMapping( arguments.projectName, variables.root );

		buildSource( argumentCollection = arguments );
		buildChecksums();

		print.line().boldMagentaLine( "Build finished. The package is in #variables.exportsDir#" ).toConsole();
	}

	/**
	 * Runs the test suite and stops the build when anything fails.
	 */
	function runTests(){
		print.blueLine( "Running the test suite, please wait..." ).toConsole();

		command( "testbox run" )
			.params( runner = variables.settings.testRunner, verbose = false )
			.run();

		if ( shell.getExitCode() ) {
			return error( "Stopping: the tests failed. Fix them, or use skipTests to build anyway." );
		}
	}

	/**
	 * Creates and verifies the source package without running the test suite.
	 *
	 * @projectName The name used for the package folder and zip.
	 * @version     The version being built.
	 * @buildID     The build identifier.
	 * @branch      The branch being built.
	 * @skipTests   Accepted so this can be called with the same arguments as run().
	 */
	function buildSource(
		string projectName = "",
		string version     = "",
		string buildID     = "",
		string branch      = "",
		boolean skipTests  = false
	){
		fillDefaults( arguments );

		print
			.line()
			.boldMagentaLine(
				"Building #arguments.projectName# #arguments.version#+#arguments.buildID# from the #arguments.branch# branch."
			)
			.toConsole();

		ensureExportDir( arguments.projectName, arguments.version );

		variables.projectBuildDir = variables.buildDir & "/#arguments.projectName#";
		directoryCreate( variables.projectBuildDir, true, true );

		copySourceToStaging();
		writeBuildMarker( argumentCollection = arguments );
		replaceBuildTokens( argumentCollection = arguments );

		var zipPath = createPackageZip( arguments.projectName, arguments.version );
		verifyZip( zipPath );
		copyPackageManifest();
	}

	// BUILD STEPS

	private void function prepareOutputDirectories(){
		for ( var directoryPath in [ variables.buildDir, variables.artifactsDir ] ) {
			if ( directoryExists( directoryPath ) ) {
				directoryDelete( directoryPath, true );
			}
			directoryCreate( directoryPath, true, true );
		}
	}

	private void function configureColdBoxMapping(){
		if ( !len( trim( variables.settings.coldboxMapping ) ) ) {
			return;
		}

		var coldboxPath = variables.root & "/" & variables.settings.coldboxMapping;
		if ( directoryExists( coldboxPath ) ) {
			fileSystemUtil.createMapping( "coldbox", coldboxPath );
		}
	}

	private void function copySourceToStaging(){
		print.blueLine( "Copying source into the staging folder..." ).toConsole();
		copy( variables.root, variables.projectBuildDir );
	}

	private void function writeBuildMarker(
		required string projectName,
		required string version,
		required string buildID
	){
		fileWrite(
			"#variables.projectBuildDir#/#arguments.projectName#-#arguments.version#+#arguments.buildID#",
			"Built from commit #arguments.buildID# on #dateTimeFormat( now(), "full" )#"
		);
	}

	private void function replaceBuildTokens(
		required string version,
		required string buildID,
		required string branch
	){
		print.greenLine( "Stamping version #arguments.version#" ).toConsole();
		command( "tokenReplace" )
			.params(
				path        = "#variables.projectBuildDir#/**",
				token       = "@build.version@",
				replacement = arguments.version
			)
			.run();

		var isReleaseBranch = arguments.branch == variables.settings.branch;
		print.greenLine( "Stamping build identifier #arguments.buildID#" ).toConsole();
		command( "tokenReplace" )
			.params(
				path        = "#variables.projectBuildDir#/**",
				token       = isReleaseBranch ? "@build.number@" : "+@build.number@",
				replacement = isReleaseBranch ? arguments.buildID : "-snapshot"
			)
			.run();
	}

	private string function createPackageZip( required string projectName, required string version ){
		var zipPath = "#variables.exportsDir#/#arguments.projectName#-#arguments.version#.zip";
		print.greenLine( "Zipping to #zipPath#" ).toConsole();
		cfzip(
			action    = "zip",
			file      = zipPath,
			source    = variables.projectBuildDir,
			overwrite = true,
			recurse   = true
		);
		return zipPath;
	}

	private void function copyPackageManifest(){
		// This copy lets someone inspect the published metadata without opening the ZIP.
		fileCopy( "#variables.projectBuildDir#/box.json", variables.exportsDir );
	}

	// SHARED HELPERS

	/**
	 * Fills in any argument left blank: the slug and version from box.json, the branch and
	 * commit from git. Doing it here means every entry point behaves the same way.
	 *
	 * @args The argument struct, changed in place.
	 */
	private void function fillDefaults( required struct args ){
		if ( !len( trim( arguments.args.projectName ?: "" ) ) ) {
			arguments.args.projectName = variables.config.slug();
		}
		if ( !len( trim( arguments.args.version ?: "" ) ) ) {
			arguments.args.version = variables.config.version();
		}
		if ( !len( trim( arguments.args.branch ?: "" ) ) ) {
			arguments.args.branch = getCurrentBranch();
		}
		if ( !len( trim( arguments.args.buildID ?: "" ) ) ) {
			arguments.args.buildID = getCurrentCommit();
		}
	}

	/**
	 * Reads the current branch from .git/HEAD without needing the git program. Falls back to
	 * the release branch from build.json when HEAD cannot be read, which happens when building
	 * from a copy with no .git folder.
	 */
	private string function getCurrentBranch(){
		var headFile = variables.root & "/.git/HEAD";
		if ( !fileExists( headFile ) ) {
			return variables.settings.branch;
		}
		var head = trim( fileRead( headFile ) );
		if ( left( head, 16 ) == "ref: refs/heads/" ) {
			return replace( head, "ref: refs/heads/", "" );
		}
		// A detached HEAD holds a commit hash, not a branch name.
		return variables.settings.branch;
	}

	/**
	 * Reads the short commit hash HEAD points at, straight from the .git folder so the git
	 * program is not needed and it still works from an extracted copy. Returns "nocommit" when
	 * there is nothing to read.
	 */
	private string function getCurrentCommit(){
		var headFile = variables.root & "/.git/HEAD";
		if ( !fileExists( headFile ) ) {
			return "nocommit";
		}
		var head       = trim( fileRead( headFile ) );
		var commitHash = "";

		if ( left( head, 5 ) == "ref: " ) {
			// The usual case: HEAD names a branch, and the hash sits in .git/<ref>, or in
			// .git/packed-refs once git has tidied it away.
			var gitReference  = trim( mid( head, 6, len( head ) ) );
			var referenceFile = variables.root & "/.git/" & gitReference;
			if ( fileExists( referenceFile ) ) {
				commitHash = trim( fileRead( referenceFile ) );
			} else {
				var packedFile = variables.root & "/.git/packed-refs";
				if ( fileExists( packedFile ) ) {
					for ( var packedReferenceLine in listToArray( fileRead( packedFile ), chr( 10 ) ) ) {
						var line = trim( packedReferenceLine );
						// Each line reads "<hash> <ref>". Skip comments and peeled tag lines.
						if ( len( line ) && left( line, 1 ) != "##" && left( line, 1 ) != "^" && right( line, len( gitReference ) ) == gitReference ) {
							commitHash = listFirst( line, " " );
							break;
						}
					}
				}
			}
		} else {
			// A detached HEAD already holds the hash.
			commitHash = head;
		}

		return len( commitHash ) ? left( commitHash, 7 ) : "nocommit";
	}

	/**
	 * Stops the build with a clear message when the test server is not answering. Kept separate
	 * from runTests() so "the server is not running" never reads as "your tests failed".
	 *
	 * It asks for the site root rather than the test runner, because asking for the runner
	 * would start the whole suite.
	 */
	private function ensureTestRunnerReachable(){
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
		// Anything in the 200s or 300s means the site answered.
		var statusCode = val( httpResult.statuscode ?: "0" );
		if ( statusCode < 200 || statusCode >= 400 ) {
			return error(
				"No answer from the test server at #probeUrl# (status #statusCode#). "
				& "Start a server first, then run this again. "
				& "To build without running the tests, add :skipTests=true."
			);
		}
	}

	/**
	 * Writes SHA-512 and MD5 files next to the zip so anyone can confirm a download is intact.
	 */
	private function buildChecksums(){
		print.greenLine( "Writing checksums" ).toConsole();
		command( "checksum" )
			.params(
				path      = "#variables.exportsDir#/*.zip",
				algorithm = "SHA-512",
				extension = "sha512",
				write     = true
			)
			.run();
		command( "checksum" )
			.params(
				path      = "#variables.exportsDir#/*.zip",
				algorithm = "md5",
				extension = "md5",
				write     = true
			)
			.run();
	}

	/**
	 * Stops the build when the zip holds fewer files than the staging folder.
	 *
	 * This is deliberately simple: it counts files rather than working out what went wrong.
	 * Counting catches any cause, including the one that started it. A published module once
	 * shipped without several folders because an ignore rule quietly matched them, and nothing
	 * failed until every app that installed it broke on startup.
	 *
	 * @zipPath The full path of the zip just written.
	 */
	private function verifyZip( required string zipPath ){
		cfzip( action = "list", file = arguments.zipPath, name = "local.zipEntries" );

		var stagedCount = directoryList( variables.projectBuildDir, true, "path" )
			.filter( function( item ){
				return fileExists( item );
			} )
			.len();

		// A zip lists folders as entries too, so only count the files.
		var zippedCount = 0;
		for ( var row in local.zipEntries ) {
			if ( row.type == "file" ) {
				zippedCount++;
			}
		}

		if ( zippedCount != stagedCount ) {
			return error(
				"The zip is incomplete: #stagedCount# files were staged but the zip holds #zippedCount#. "
				& "Check .gitignore and the excludes in build/build.json for a rule matching source files. "
				& "Staging folder: #variables.projectBuildDir#"
			);
		}

		print.greenLine( "Checked: the zip holds all #zippedCount# staged files." ).toConsole();
	}

	/**
	 * Copies the project into the staging folder, leaving out anything the excludes match.
	 * Written by hand because directoryCopy with a filter is unreliable on Lucee.
	 *
	 * Only top-level names are tested. A folder that survives is copied whole, so a file
	 * inside it cannot be excluded from here.
	 *
	 * @src    The folder to copy from.
	 * @target The folder to copy into.
	 */
	private function copy( required string src, required string target ){
		var excludes = variables.config.allExcludes();
		// Hold this in a plain variable: inside the closures below, "arguments" means the
		// closure's own arguments, so arguments.target would be missing.
		var targetDir = arguments.target;

		directoryList(
			arguments.src,
			false,
			"path",
			function( path ){
				var isExcluded = false;
				var name       = relativeName( path );
				excludes.each( function( pattern ){
					if ( name.reFindNoCase( pattern ) ) {
						isExcluded = true;
					}
				} );
				return !isExcluded;
			}
		).each( function( item ){
			var name = relativeName( item );
			if ( fileExists( item ) ) {
				print.blueLine( "  copy #name#" ).toConsole();
				fileCopy( item, targetDir );
			} else {
				print.greenLine( "  copy folder #name#" ).toConsole();
				directoryCopy( item, targetDir & "/" & name, true );
			}
		} );
	}

	/**
	 * Turns a full path into its name relative to the project root, for example
	 * "models" or "box.json".
	 *
	 * Both sides are put into the same shape first. directoryList returns paths using the
	 * system separator, so comparing them against a path built with a different separator
	 * quietly matches nothing and leaves the full path in place.
	 *
	 * @path The full path to shorten.
	 */
	private string function relativeName( required string path ){
		var normalisedPath = replace( arguments.path, "\", "/", "all" );
		var normalisedRoot = replace( variables.root, "\", "/", "all" );

		var name = replaceNoCase( normalisedPath, normalisedRoot, "", "one" );
		// Drop the separators left at either end.
		return reReplace( reReplace( name, "^[\\/]+", "" ), "[\\/]+$", "" );
	}

	/**
	 * Creates .artifacts/<name>/<version>/ and remembers it for the rest of the build.
	 *
	 * @projectName The package name.
	 * @version     The version being built.
	 */
	private function ensureExportDir( required string projectName, required string version ){
		if ( structKeyExists( variables, "exportsDir" ) && directoryExists( variables.exportsDir ) ) {
			return;
		}
		variables.exportsDir = variables.artifactsDir & "/#arguments.projectName#/#arguments.version#";
		directoryCreate( variables.exportsDir, true, true );
	}
}
