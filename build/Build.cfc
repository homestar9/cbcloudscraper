/**
 * Builds and checks the package files that will be published.
 *
 * Run `box run-script build:package` from the project root. The task runs the tests, copies
 * allowed source files into a clean staging folder, replaces version tokens, creates a ZIP,
 * verifies the ZIP, and writes checksum files.
 *
 * Build files go in .artifacts/<slug>/<version>/. Use `:skipTests=true` only when the same source
 * code has already passed the tests. Project settings come from build/build.json.
 */
component {

	/** Load settings and prepare empty staging and artifact directories. */
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
	 * Run the tests, build the package, and write checksum files.
	 *
	 * @projectName The name used for the package folder and zip. Defaults to the box.json slug.
	 * @version     The version being built. Defaults to the box.json version.
	 * @buildID     The build identifier. When blank, uses the short git commit hash.
	 * @branch      The branch being built. When blank, reads the current branch.
	 * @skipTests   Skip the test suite for this run. Use only when this version has already passed.
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

		// Add a CFML mapping so the build can load components from the project.
		fileSystemUtil.createMapping( arguments.projectName, variables.root );

		buildSource( argumentCollection = arguments );
		buildChecksums();

		print.line().boldMagentaLine( "Build finished. The package is in #variables.exportsDir#" ).toConsole();
	}

	/**
	 * Run the test suite and stop the build when any test fails.
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
	 * Create and check the source package without running the test suite.
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

	// Build steps

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
		// Keep a copy beside the ZIP so developers can inspect the metadata without opening it.
		fileCopy( "#variables.projectBuildDir#/box.json", variables.exportsDir );
	}

	// Shared helpers

	/**
	 * Fill blank arguments with the slug and version from box.json or the branch and commit from
	 * Git. All build entry points call this method, so they use the same default values.
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
	 * Read the current branch from .git/HEAD without running Git. Return the release branch from
	 * build.json when HEAD is missing or cannot be read.
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
		// A detached HEAD contains a commit hash instead of a branch name.
		return variables.settings.branch;
	}

	/**
	 * Read the short commit hash from the .git directory without running Git. Return "nocommit"
	 * when the commit cannot be found.
	 */
	private string function getCurrentCommit(){
		var headFile = variables.root & "/.git/HEAD";
		if ( !fileExists( headFile ) ) {
			return "nocommit";
		}
		var head       = trim( fileRead( headFile ) );
		var commitHash = "";

		if ( left( head, 5 ) == "ref: " ) {
			// When HEAD names a branch, read the hash from its reference file. Git may move older
			// reference files into .git/packed-refs, so check that file as a fallback.
			var gitReference  = trim( mid( head, 6, len( head ) ) );
			var referenceFile = variables.root & "/.git/" & gitReference;
			if ( fileExists( referenceFile ) ) {
				commitHash = trim( fileRead( referenceFile ) );
			} else {
				var packedFile = variables.root & "/.git/packed-refs";
				if ( fileExists( packedFile ) ) {
					for ( var packedReferenceLine in listToArray( fileRead( packedFile ), chr( 10 ) ) ) {
						var line = trim( packedReferenceLine );
						// Each line contains "<hash> <ref>". Ignore comments and peeled annotated-tag lines.
						if ( len( line ) && left( line, 1 ) != "##" && left( line, 1 ) != "^" && right( line, len( gitReference ) ) == gitReference ) {
							commitHash = listFirst( line, " " );
							break;
						}
					}
				}
			}
		} else {
			// A detached HEAD contains the commit hash directly.
			commitHash = head;
		}

		return len( commitHash ) ? left( commitHash, 7 ) : "nocommit";
	}

	/**
	 * Stop the build when the test server does not respond. Keep this check separate from
	 * runTests() so the error clearly says that the server failed, not the tests.
	 *
	 * Request the site root instead of the test runner URL. Requesting the runner would start
	 * the full suite during this server check.
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
		// Any 2xx or 3xx status proves that the site responded.
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
	 * Write SHA-512 and MD5 files beside the ZIP so downloads can be checked for corruption.
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
	 * Stop the build when the ZIP contains fewer files than the staging directory.
	 *
	 * Count files instead of guessing which packaging rule failed. This catches any missing file.
	 * This check exists because an ignore rule once removed required directories from a published
	 * module, which caused installed applications to fail during startup.
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

		// ZIP listings include directory entries, so count only file entries.
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
	 * Copy the project into the staging directory and skip excluded top-level items. This uses
	 * explicit file operations because directoryCopy filters are unreliable on Lucee.
	 *
	 * Check exclusions only against top-level names. When a directory is included, copy all files
	 * inside that directory.
	 *
	 * @src    The folder to copy from.
	 * @target The folder to copy into.
	 */
	private function copy( required string src, required string target ){
		var excludes = variables.config.allExcludes();
		// Save the target in a local variable. Inside each closure, arguments belongs to the closure
		// and does not contain the outer function's target argument.
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
	 * Convert a full path to a path relative to the project root, such as "models" or "box.json".
	 *
	 * Normalize both paths before comparing them. directoryList uses the operating system's path
	 * separator. A path built with a different separator would not match and would remain absolute.
	 *
	 * @path The full path to shorten.
	 */
	private string function relativeName( required string path ){
		var normalisedPath = replace( arguments.path, "\", "/", "all" );
		var normalisedRoot = replace( variables.root, "\", "/", "all" );

		var name = replaceNoCase( normalisedPath, normalisedRoot, "", "one" );
		// Remove path separators from both ends of the relative path.
		return reReplace( reReplace( name, "^[\\/]+", "" ), "[\\/]+$", "" );
	}

	/**
	 * Create .artifacts/<name>/<version>/ and save its path for later build steps.
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
