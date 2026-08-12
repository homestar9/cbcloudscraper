/**
 * Adds this build kit's files and commands to a CFML project.
 *
 * Run `box task run taskFile=build/Install.cfc` from the project root. The task creates
 * build/build.json, adds release scripts to box.json, creates a changelog when needed, and
 * copies RELEASE.md into the project root.
 *
 * The task keeps existing files unless you pass `:force=true`. It reads box.json, Git, and
 * server JSON files in the project root to choose useful default settings.
 */
component {

	/**
	 * Run each installation step and print the settings found in the project.
	 *
	 * @force Overwrite files that already exist.
	 */
	function run( boolean force = false ){
		variables.buildDir = getDirectoryFromPath( getCurrentTemplatePath() );
		variables.root     = reReplace( reReplace( variables.buildDir, "[\\/]$", "" ), "[\\/][^\\/]+$", "" );
		variables.projectSettings = new lib.ProjectSettingsService();

		print.line().boldLine( "Setting up the build kit" ).line( repeatString( "-", 60 ) ).toConsole();

		if ( !fileExists( variables.root & "/box.json" ) ) {
			return error(
				"No box.json found at #variables.root#. Run this from a CommandBox package: "
				& "put this build folder in your project root and run the command from there."
			);
		}

		writeBuildJSON( arguments.force );
		patchBoxJSON();
		writeChangelog( arguments.force );
		copyReleaseDoc( arguments.force );

		print
			.line( repeatString( "-", 60 ) )
			.boldGreenLine( "Done." )
			.line()
			.boldLine( "Next steps:" )
			.line( "  1. Look through build/build.json and adjust anything that is wrong." )
			.line( "  2. Check you are ready:   box run-script release:check" )
			.line( "  3. Rehearse a release:    box run-script release:dryrun" )
			.line()
			.line( "RELEASE.md in your project root explains the whole routine." )
			.toConsole();
	}

	// Installation steps

	/**
	 * Write build/build.json and fill in settings found in the project.
	 *
	 * @force Overwrite an existing file.
	 */
	private function writeBuildJSON( required boolean force ){
		var path          = variables.buildDir & "build.json";
		var replacingSeed = fileExists( path ) && isInstallerSeed( path );
		if ( fileExists( path ) && !arguments.force && !replacingSeed ) {
			print.yellowLine( "  skip  build/build.json already exists (use :force=true to replace it)" ).toConsole();
			return;
		}

		var packageData = deserializeJSON( fileRead( variables.root & "/box.json" ) );
		var projectType = variables.projectSettings.detectProjectType( packageData );
		var settings = {
			"templateVersion" : "1.0.0",
			"projectType"     : projectType,
			"branch"          : detectBranch(),
			"changelog"       : detectChangelogName(),
			"testRunner"      : detectTestRunner( packageData ),
			"runTests"        : true,
			"publish"         : {
				"forgebox" : projectType == "module",
				"github"   : true
			},
			"excludes"    : variables.projectSettings.installerDefaultExcludes( projectType ),
			"excludesAdd" : [],
			"engines"     : detectEngines()
		};

		fileWrite( path, formatJSON( settings ) );
		print.greenLine( "  made  build/build.json#( replacingSeed ? " (replaced starter config)" : "" )#" ).toConsole();
		print.line( "        project type:   #settings.projectType#" ).toConsole();
		print.line( "        release branch: #settings.branch#" ).toConsole();
		print.line( "        test runner:    #settings.testRunner#" ).toConsole();
		print.line( "        engines:        #arrayLen( settings.engines )# found" ).toConsole();
	}

	/**
	 * Return true when build.json is the starter file included with this kit. The installer can
	 * replace a marked starter file without force. It does not replace custom or invalid files.
	 *
	 * @path The build.json file to inspect.
	 */
	private boolean function isInstallerSeed( required string path ){
		try {
			var settings = deserializeJSON( fileRead( arguments.path ) );
			return isStruct( settings )
				&& isBoolean( settings._installerSeed ?: false )
				&& settings._installerSeed;
		} catch ( any ignoredException ) {
			return false;
		}
	}

	/**
	 * Add missing build-kit scripts to box.json. Keep every existing script unchanged.
	 */
	private function patchBoxJSON(){
		var packagePath = variables.root & "/box.json";
		var packageData = deserializeJSON( fileRead( packagePath ) );

		if ( !structKeyExists( packageData, "scripts" ) ) {
			packageData[ "scripts" ] = {};
		}

		var requiredScripts = {
			"release"         : "task run taskFile=build/Release.cfc target=run :version=`package show version`",
			"release:check"   : "task run taskFile=build/Doctor.cfc",
			"release:dryrun"  : "task run taskFile=build/Release.cfc target=run :version=`package show version` :dryRun=true",
			"release:existing-tag" : "task run taskFile=build/Release.cfc target=run :version=`package show version` :existingTag=true",
			"release:skip-tests" : "task run taskFile=build/Release.cfc target=run :version=`package show version` :skipTests=true",
			"release:hotfix"  : "task run taskFile=build/Release.cfc target=run :version=`package show version` :skipTests=true",
			"test:engines"    : "task run taskFile=build/TestEngines.cfc",
			"bump:major"      : "task run taskFile=build/Bump.cfc :level=major",
			"bump:minor"      : "task run taskFile=build/Bump.cfc :level=minor",
			"bump:patch"      : "task run taskFile=build/Bump.cfc :level=patch",
			"bump:prerelease" : "task run taskFile=build/Bump.cfc :level=prerelease",
			"bump:beta"       : "task run taskFile=build/Bump.cfc :level=preminor :preid=beta",
			"bump:alpha"      : "task run taskFile=build/Bump.cfc :level=preminor :preid=alpha",
			"build:package"   : "task run taskFile=build/Build.cfc :projectName=`package show slug` :version=`package show version`"
		};

		var addedScripts    = [];
		var existingScripts = [];
		for ( var scriptName in requiredScripts ) {
			if ( structKeyExists( packageData.scripts, scriptName ) ) {
				existingScripts.append( scriptName );
			} else {
				packageData.scripts[ scriptName ] = requiredScripts[ scriptName ];
				addedScripts.append( scriptName );
			}
		}

		if ( arrayLen( addedScripts ) ) {
			fileWrite( packagePath, formatJSON( packageData ) );
			var scriptCount = arrayLen( addedScripts );
			var scriptLabel = scriptCount == 1 ? "script" : "scripts";
			print
				.greenLine( "  added #scriptCount# #scriptLabel# to box.json: #addedScripts.sort( "text" ).toList( ", " )#" )
				.toConsole();
		} else {
			print.yellowLine( "  skip  box.json already has every script" ).toConsole();
		}
		if ( arrayLen( existingScripts ) ) {
			print.line( "        left alone: #existingScripts.sort( "text" ).toList( ", " )#" ).toConsole();
		}
	}

	/**
	 * Create a changelog with an [Unreleased] section when the project does not have one.
	 *
	 * @force Overwrite an existing changelog.
	 */
	private function writeChangelog( required boolean force ){
		var name = detectChangelogName();
		var path = variables.root & "/" & name;

		if ( fileExists( path ) && !arguments.force ) {
			print.yellowLine( "  skip  #name# already exists" ).toConsole();
			return;
		}

		var template = variables.buildDir & "templates/CHANGELOG.md";
		if ( fileExists( template ) ) {
			fileCopy( template, path );
		} else {
			fileWrite( path, defaultChangelog() );
		}
		print.greenLine( "  made  #name#" ).toConsole();
	}

	/**
	 * Copy RELEASE.md into the project root so contributors can find the release steps.
	 *
	 * @force Overwrite an existing RELEASE.md.
	 */
	private function copyReleaseDoc( required boolean force ){
		var source = variables.buildDir & "templates/RELEASE.md";
		var target = variables.root & "/RELEASE.md";

		if ( !fileExists( source ) ) {
			return;
		}
		if ( fileExists( target ) && !arguments.force ) {
			print.yellowLine( "  skip  RELEASE.md already exists" ).toConsole();
			return;
		}
		fileCopy( source, target );
		print.greenLine( "  made  RELEASE.md" ).toConsole();
	}

	// Project detection

	/**
	 * Return Gitflow's production branch when it is configured. Otherwise, ask Git for the current
	 * branch. Asking Git also works in linked worktrees. Return main for a detached checkout or
	 * when Git metadata is not available.
	 */
	private string function detectBranch(){
		try {
			var config     = new BuildConfig( variables.buildDir );
			var production = config.execNative( "git", [ "config", "--get", "gitflow.branch.master" ] );
			if ( production.exitCode == 0 && len( trim( production.output ) ) ) {
				return trim( production.output );
			}

			var current = config.execNative( "git", [ "symbolic-ref", "--quiet", "--short", "HEAD" ] );
			if ( current.exitCode == 0 && len( trim( current.output ) ) ) {
				return trim( current.output );
			}
		} catch ( any ignored ) {
			// The installer can still create a useful starter configuration without Git.
		}
		return "main";
	}

	/**
	 * Return the existing changelog filename with the same letter case used on disk. Return
	 * CHANGELOG.md when the project does not have a changelog.
	 *
	 * Read the directory listing instead of calling fileExists for possible names. Windows and
	 * macOS may report that changelog.md exists when the file is named CHANGELOG.md. Linux requires
	 * the exact letter case. Saving the wrong case in build.json would fail on Linux.
	 */
	private string function detectChangelogName(){
		for ( var name in directoryList( variables.root, false, "name", "*.md" ) ) {
			if ( reFindNoCase( "^changelog\.md$", name ) ) {
				return name;
			}
		}
		return "CHANGELOG.md";
	}

	/**
	 * Return the test runner URL chosen by ProjectSettingsService.
	 *
	 * @box The parsed box.json data.
	 */
	private string function detectTestRunner( required struct box ){
		return variables.projectSettings.detectTestRunner( arguments.box );
	}

	/**
	 * Find server JSON files in the project root and build an engine entry for each file.
	 */
	private array function detectEngines(){
		var engines = [];
		var files   = directoryList( variables.root, false, "name", "*.json" )
			.filter( function( file ){
				return reFindNoCase( "^server(?:-.*)?\.json$", file );
			} );
		files.sort( "textnocase" );

		for ( var file in files ) {
			engines.append( { "name" : engineName( file ), "configFile" : file } );
		}
		return engines;
	}

	/**
	 * Read one server file and ask ProjectSettingsService to choose its display name. If the JSON
	 * is invalid, use a name based on the filename so the generated settings still include it.
	 *
	 * @file The server json file name.
	 */
	private string function engineName( required string file ){
		var serverSettings = {};
		try {
			var parsedSettings = deserializeJSON( fileRead( variables.root & "/" & arguments.file ) );
			serverSettings = isStruct( parsedSettings ) ? parsedSettings : {};
		} catch ( any ignoredException ) {
			// CommandBox will report the invalid JSON when a developer starts this server.
		}

		return variables.projectSettings.engineName( arguments.file, serverSettings );
	}

	// Output helpers

	/**
	 * Convert a struct to readable JSON. Use the CommandBox formatter when it is available so the
	 * result matches the formatting in box.json.
	 *
	 * @data The struct to write.
	 */
	private string function formatJSON( required struct data ){
		var json = serializeJSON( arguments.data );
		try {
			return formatterUtil.formatJSON( json );
		} catch ( any ignoredException ) {
			return json;
		}
	}

	/**
	 * Return the starter changelog when the template file is missing.
	 */
	private string function defaultChangelog(){
		var lf = chr( 10 );
		// Build Markdown headings with chr(35). A # starts a CFML expression inside a string, so
		// writing heading markers directly would require extra escaping and be easy to count wrong.
		var h1 = repeatString( chr( 35 ), 1 ) & " ";
		var h2 = repeatString( chr( 35 ), 2 ) & " ";
		var h3 = repeatString( chr( 35 ), 3 ) & " ";

		return h1 & "Changelog" & lf & lf
			& "All notable changes to this project are written down here." & lf & lf
			& "The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)," & lf
			& "and the version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)." & lf & lf
			& h2 & "[Unreleased]" & lf & lf
			& h3 & "Added" & lf & lf
			& "- Write your changes here as you go." & lf;
	}
}
