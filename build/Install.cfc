/**
 * Adds the build kit files and commands to a CFML project.
 *
 * Run `box task run taskFile=build/Install.cfc` from the project root. The task creates
 * build/build.json, adds release scripts to box.json, creates a changelog when needed, and
 * copies RELEASE.md into the project root.
 *
 * The task keeps existing files unless `:force=true` is passed. It detects useful defaults
 * from box.json, Git, and root-level server JSON files.
 */
component {

	/**
	 * Runs each installation step and prints the detected settings.
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

	// INSTALLATION STEPS

	/**
	 * Writes build/build.json, filling in what it can work out from the project.
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
	 * Reports whether build.json is the starter file shipped with this kit. Only a marked
	 * starter can be replaced without force; malformed and user-owned files remain untouched.
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
	 * Adds missing build-kit scripts to box.json. It never replaces an existing script.
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
	 * Creates a changelog with an [Unreleased] section when the project has none.
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
	 * Copies RELEASE.md into the project root so the routine is written down where people
	 * will find it.
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

	// PROJECT DETECTION

	/**
	 * Uses Gitflow's configured production branch when present. Otherwise reads the current
	 * symbolic branch through git, which also works in linked worktrees, and falls back to main
	 * for a detached checkout or a folder without usable git metadata.
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
			// Installation can still produce a useful starter config when git is unavailable.
		}
		return "main";
	}

	/**
	 * Returns the name of the changelog the project already has, spelled exactly as it is on
	 * disk. Falls back to CHANGELOG.md, which is the usual spelling.
	 *
	 * It reads the real directory listing rather than testing names one at a time. On Windows
	 * and macOS, fileExists( "changelog.md" ) is true even when the file is really called
	 * CHANGELOG.md, so testing names would happily report a spelling that does not exist. That
	 * name then goes into build.json and works locally while failing on Linux, where the case
	 * has to match.
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
	 * Returns the test runner detected by ProjectSettingsService.
	 *
	 * @box The parsed box.json. This wrapper remains private to keep file detection readable.
	 */
	private string function detectTestRunner( required struct box ){
		return variables.projectSettings.detectTestRunner( arguments.box );
	}

	/**
	 * Finds the server json files in the project root and turns them into engine entries, with
	 * a readable name worked out from each file name.
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
	 * Reads one server file and asks ProjectSettingsService to choose its display name.
	 * A malformed file still appears in the generated settings with a name based on its file.
	 *
	 * @file The server json file name.
	 */
	private string function engineName( required string file ){
		var serverSettings = {};
		try {
			var parsedSettings = deserializeJSON( fileRead( variables.root & "/" & arguments.file ) );
			serverSettings = isStruct( parsedSettings ) ? parsedSettings : {};
		} catch ( any ignoredException ) {
			// The server command will report invalid JSON when someone starts this server.
		}

		return variables.projectSettings.engineName( arguments.file, serverSettings );
	}

	// OUTPUT HELPERS

	/**
	 * Turns a struct into readable JSON. CommandBox's own formatter is used when available so
	 * the result matches how it writes box.json.
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
	 * The starter changelog, used when the templates folder is missing.
	 */
	private string function defaultChangelog(){
		var lf = chr( 10 );
		// Build the markdown headings from chr( 35 ) rather than writing hashes in the string.
		// A # starts a variable in CFML, so hashes have to be doubled, and counting them for a
		// three-hash heading is a good way to write a bug.
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
