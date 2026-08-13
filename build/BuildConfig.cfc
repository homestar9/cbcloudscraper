/**
 * Loads and checks the settings shared by all build tasks.
 *
 * Each task passes its build directory to init(). BuildConfig then finds the project root, reads
 * build/build.json, adds default values, and checks the final settings. BuildConfig also provides
 * shared path helpers and runs Git or GitHub CLI commands.
 *
 * Projects configure this component through build/build.json. A project should not need to
 * edit this file.
 */
component {

	/**
	 * Find the project root and load the complete settings struct.
	 *
	 * @buildDir The build folder that contains this component.
	 */
	function init( required string buildDir ){
		variables.buildDir = reReplace( arguments.buildDir, "[\\/]$", "" );
		variables.root        = reReplace( variables.buildDir, "[\\/][^\\/]+$", "" );
		variables.binaryCache = {};
		variables.touchedKeys    = {};
		variables.projectSettings = new lib.ProjectSettingsService();
		variables.settings       = loadSettings();
		return this;
	}

	/**
	 * Return the complete settings struct.
	 */
	struct function getSettings(){
		return variables.settings;
	}

	/**
	 * Return one setting.
	 *
	 * @key          The setting name, for example "branch".
	 * @defaultValue What to return when the setting is missing.
	 */
	function get( required string key, defaultValue = "" ){
		return structKeyExists( variables.settings, arguments.key ) ? variables.settings[ arguments.key ] : arguments.defaultValue;
	}

	/**
	 * Convert a path relative to the project root into a full path.
	 *
	 * Do not rename this method to resolvePath. CommandBox provides its own resolvePath() to tasks.
	 * That method takes priority and starts from the task file's directory, not the project root.
	 * The wrong method would return an incorrect path without reporting an error.
	 *
	 * @relative A path relative to the project root, for example "CHANGELOG.md".
	 */
	string function repoPath( required string relative ){
		return variables.root & "/" & arguments.relative;
	}

	/**
	 * Convert a path relative to the build directory into a full path.
	 *
	 * @relative A path relative to the build folder, for example "templates/RELEASE.md".
	 */
	string function buildPath( required string relative ){
		return variables.buildDir & "/" & arguments.relative;
	}

	/**
	 * Return the full path to the project root.
	 */
	string function getRoot(){
		return variables.root;
	}

	/**
	 * Read and return the project's box.json data.
	 */
	struct function boxJSON(){
		var path = repoPath( "box.json" );
		if ( !fileExists( path ) ) {
			throw( type = "BuildConfig", message = "No box.json found at #path#. Run build tasks from a CommandBox package." );
		}
		return deserializeJSON( fileRead( path ) );
	}

	/**
	 * Return the package slug from box.json. Use the package name when the slug is missing.
	 */
	string function slug(){
		var box = boxJSON();
		return box.slug ?: ( box.name ?: "package" );
	}

	/**
	 * Return the version from box.json.
	 */
	string function version(){
		return boxJSON().version ?: "0.0.0";
	}

	/**
	 * Run a program such as git or gh. Return its exit code and text output without throwing an
	 * exception. The caller decides what a failure means. Some checks expect a nonzero exit code,
	 * such as `git rev-parse --verify` when a reference does not exist.
	 *
	 * Pass each argument as a separate list item. Paths with spaces do not need quotes and cannot
	 * be split into separate arguments.
	 *
	 * Run the program through Java because CommandBox does not give command() or shell helpers to
	 * plain components. The program runs without a shell, so pipes, output redirection, and wildcard
	 * expansion are not available. Release commands only need one program with plain arguments.
	 *
	 * @name The program name, for example "git".
	 * @args The arguments, for example [ "status", "--porcelain" ].
	 */
	struct function execNative( required string name, array args = [] ){
		var binary  = findBinary( arguments.name );
		var argList = createObject( "java", "java.util.ArrayList" ).init();
		argList.add( javaCast( "string", binary ) );
		for ( var arg in arguments.args ) {
			argList.add( javaCast( "string", arg ) );
		}

		try {
			var builder = createObject( "java", "java.lang.ProcessBuilder" ).init( argList );
			builder.directory( createObject( "java", "java.io.File" ).init( variables.root ) );
			// Combine standard error with standard output so callers receive one useful text block.
			builder.redirectErrorStream( javaCast( "boolean", true ) );

			var process = builder.start();
			var reader  = createObject( "java", "java.io.BufferedReader" ).init(
				createObject( "java", "java.io.InputStreamReader" ).init( process.getInputStream() )
			);

			var output = createObject( "java", "java.lang.StringBuilder" ).init();
			var line   = reader.readLine();
			while ( !isNull( line ) ) {
				output.append( line ).append( chr( 10 ) );
				line = reader.readLine();
			}
			reader.close();

			return { exitCode : process.waitFor(), output : trim( output.toString() ) };
		} catch ( any exception ) {
			// Most exceptions here mean the program is missing. Return 127 because callers already
			// recognize that value as the standard "command not found" exit code.
			return {
				exitCode : 127,
				output   : "Could not run '#arguments.name#': #exception.message#"
			};
		}
	}

	/**
	 * Return true when the program can be found and started.
	 *
	 * @name The program name, for example "gh".
	 */
	boolean function commandExists( required string name ){
		// resolveExecutable returns the original name when it cannot find a full path.
		return findBinary( arguments.name ) != arguments.name;
	}

	/**
	 * Find a program and return its full path, such as C:\Program Files\Git\cmd\git.exe. Return
	 * the original name when no file is found. Java can then try the operating system's normal
	 * lookup and return a readable error when the program is missing.
	 *
	 * Return the path without quotes. execNative() passes the path as one argument, so spaces are
	 * safe. Adding quotes would make the quote characters part of the filename.
	 *
	 * Search PATH first, then common installation directories. A terminal keeps its old PATH when
	 * a tool is installed after the terminal opens. The second search can still find that tool.
	 *
	 * Results are remembered for the life of the task.
	 *
	 * @name The program name, for example "git", "gh".
	 */
	string function findBinary( required string name ){
		if ( structKeyExists( variables.binaryCache, arguments.name ) ) {
			return variables.binaryCache[ arguments.name ];
		}

		var jFile     = createObject( "java", "java.io.File" );
		var separator = jFile.separator;
		var resolved  = arguments.name;
		// macOS and Linux use no extension. Windows may use any of the other listed extensions.
		var extensions = [ "", ".exe", ".cmd", ".bat" ];

		var searchDirs = [];
		var pathEnv    = createObject( "java", "java.lang.System" ).getenv( "PATH" );
		if ( !isNull( pathEnv ) ) {
			searchDirs.append( listToArray( pathEnv, jFile.pathSeparator ), true );
		}
		searchDirs.append( wellKnownDirs(), true );

		for ( var searchDirectory in searchDirs ) {
			if ( !len( trim( searchDirectory ) ) ) {
				continue;
			}
			for ( var extension in extensions ) {
				var candidate = reReplace( searchDirectory, "[\\/]$", "" ) & separator & arguments.name & extension;
				if ( fileExists( candidate ) ) {
					resolved = candidate;
					break;
				}
			}
			if ( resolved != arguments.name ) {
				break;
			}
		}

		variables.binaryCache[ arguments.name ] = resolved;
		return resolved;
	}

	// Program paths

	/**
	 * Return common installation directories to search when PATH does not contain a program.
	 */
	private array function wellKnownDirs(){
		var system      = createObject( "java", "java.lang.System" );
		var directories = [];

		var programFiles    = system.getenv( "ProgramFiles" );
		var programFilesX86 = system.getenv( "ProgramFiles(x86)" );
		var localAppData    = system.getenv( "LOCALAPPDATA" );

		if ( !isNull( programFiles ) ) {
			directories.append( programFiles & "\GitHub CLI" );
			directories.append( programFiles & "\Git\cmd" );
			directories.append( programFiles & "\Git\bin" );
			directories.append( programFiles & "\nodejs" );
		}
		if ( !isNull( programFilesX86 ) ) {
			directories.append( programFilesX86 & "\GitHub CLI" );
			directories.append( programFilesX86 & "\Git\cmd" );
		}
		if ( !isNull( localAppData ) ) {
			directories.append( localAppData & "\Programs\GitHub CLI" );
			directories.append( localAppData & "\Microsoft\WinGet\Links" );
			directories.append( localAppData & "\Programs\Git\cmd" );
		}

		directories.append( "/usr/local/bin" );
		directories.append( "/usr/bin" );
		directories.append( "/bin" );
		directories.append( "/opt/homebrew/bin" );
		directories.append( "/opt/local/bin" );
		directories.append( "/snap/bin" );

		return directories;
	}

	// Settings

	/**
	 * Build the settings struct. Start with defaults, replace them with values from build.json,
	 * then check that the final values are valid.
	 */
	private struct function loadSettings(){
		var result   = defaults();
		var jsonPath = buildPath( "build.json" );

		if ( fileExists( jsonPath ) ) {
			var settingsText = trim( fileRead( jsonPath ) );
			if ( len( settingsText ) ) {
				var userSettings = "";
				try {
					userSettings = deserializeJSON( settingsText );
				} catch ( any exception ) {
					throw(
						type    = "BuildConfig",
						message = "build/build.json is not valid JSON (#exception.message#). "
							& "Two common causes are an unquoted value and a single backslash. "
							& "Backslashes must be doubled in JSON, so a regular expression looks like ""\\.avif$""."
					);
				}
				if ( !isStruct( userSettings ) ) {
					throw( type = "BuildConfig", message = "build/build.json must hold a JSON object, for example { ""branch"": ""main"" }." );
				}
				result = merge( result, userSettings );
			}
		}

		applyProjectTypeDefaults( result );
		fillDerivedDefaults( result );
		validate( result );
		return result;
	}

	/**
	 * Return the settings used when build.json does not provide a value.
	 */
	private struct function defaults(){
		return {
			"templateVersion" : "1.0.0",
			"projectType"     : "module",
			"branch"          : "main",
			"changelog"       : "CHANGELOG.md",
			// An empty value uses testbox.runner from box.json or the fallback URL below.
			"testRunner"      : "",
			"runTests"        : true,
			"gitSync"         : true,
			"requireCleanTree": true,
			"coldboxMapping"  : "test-harness/coldbox",
			"stagingDir"      : ".tmp",
			"artifactsDir"    : ".artifacts",
			"tagPrefix"       : "v",
			"publish"         : { "forgebox" : true, "github" : true },
			"excludes"        : variables.projectSettings.buildConfigDefaultExcludes(),
			"excludesAdd"     : [],
			"engines"         : [],
			"warmup"          : { "attempts" : 60, "delaySeconds" : 5 }
		};
	}

	/**
	 * Adjust default settings for the project type. Applications are not normally published to
	 * ForgeBox, so disable that step unless build.json enables it.
	 *
	 * @settings The settings struct, changed in place.
	 */
	private void function applyProjectTypeDefaults( required struct settings ){
		// Keep an explicit publish.forgebox value from build.json. Only replace the default value.
		if ( lCase( arguments.settings.projectType ) == "app" && !userTouched( "publish.forgebox" ) ) {
			arguments.settings.publish.forgebox = false;
		}
	}

	/**
	 * Fill settings that can be read from the project. This keeps build.json short. The current
	 * project-based setting is the test runner URL from testbox.runner in box.json.
	 *
	 * @settings The settings struct, changed in place.
	 */
	private void function fillDerivedDefaults( required struct settings ){
		if ( len( trim( arguments.settings.testRunner ) ) ) {
			return;
		}
		var packageData = {};
		try {
			packageData = boxJSON();
		} catch ( any ignoredException ) {
			packageData = {};
		}
		arguments.settings.testRunner = variables.projectSettings.detectTestRunner( packageData );
	}

	/**
	 * Merge overlay values into a base struct. Merge nested structs one key at a time. This lets
	 * build.json set publish.github while keeping the default publish.forgebox value. Replace arrays
	 * completely because combining part of two ordered lists would create unclear settings.
	 *
	 * @base    The starting struct.
	 * @overlay The values that should replace matching base values.
	 */
	private struct function merge( required struct base, required struct overlay ){
		var result = duplicate( arguments.base );
		for ( var key in arguments.overlay ) {
			var incoming = arguments.overlay[ key ];
			if (
				structKeyExists( result, key )
				&& isStruct( result[ key ] )
				&& isStruct( incoming )
			) {
				result[ key ] = merge( result[ key ], incoming );
				for ( var sub in incoming ) {
					variables.touchedKeys[ key & "." & sub ] = true;
				}
			} else {
				result[ key ] = incoming;
				variables.touchedKeys[ key ] = true;
			}
		}
		return result;
	}

	/**
	 * Return true when build.json contains a key. This prevents calculated defaults from replacing
	 * a value chosen by the developer.
	 *
	 * @key The key, for example "publish.forgebox".
	 */
	private boolean function userTouched( required string key ){
		return structKeyExists( variables.touchedKeys ?: {}, arguments.key );
	}

	/**
	 * Run each group of validation rules after all default values are applied.
	 *
	 * @settings The settings struct to check.
	 */
	private void function validate( required struct settings ){
		validateProjectSettings( arguments.settings );
		validatePublishSettings( arguments.settings );
		validatePackageSettings( arguments.settings );
		validateEngineSettings( arguments.settings );
		validateWarmupSettings( arguments.settings );
		validateTestRunner( arguments.settings );
	}

	private void function validateProjectSettings( required struct settings ){
		if ( !listFindNoCase( "module,app", arguments.settings.projectType ) ) {
			throw(
				type    = "BuildConfig",
				message = "build.json projectType must be ""module"" or ""app"", "
					& "not ""#arguments.settings.projectType#""."
			);
		}
		if ( !len( trim( arguments.settings.branch ) ) ) {
			throw( type = "BuildConfig", message = "build.json branch cannot be empty. Use the branch you release from, for example ""main""." );
		}
		if ( !len( trim( arguments.settings.changelog ) ) ) {
			throw( type = "BuildConfig", message = "build.json changelog cannot be empty. Name your changelog file, for example ""CHANGELOG.md""." );
		}
		if ( !isBoolean( arguments.settings.runTests ) ) {
			throw( type = "BuildConfig", message = "build.json runTests must be true or false." );
		}
	}

	private void function validatePublishSettings( required struct settings ){
		if (
			!isStruct( arguments.settings.publish )
			|| !structKeyExists( arguments.settings.publish, "forgebox" )
			|| !structKeyExists( arguments.settings.publish, "github" )
		) {
			throw( type = "BuildConfig", message = "build.json publish must look like { ""forgebox"": true, ""github"": true }." );
		}
		if ( !isBoolean( arguments.settings.publish.forgebox ) || !isBoolean( arguments.settings.publish.github ) ) {
			throw( type = "BuildConfig", message = "build.json publish.forgebox and publish.github must be true or false." );
		}
	}

	private void function validatePackageSettings( required struct settings ){
		if ( !isArray( arguments.settings.excludes ) || !isArray( arguments.settings.excludesAdd ) ) {
			throw( type = "BuildConfig", message = "build.json excludes and excludesAdd must be arrays of regular expressions." );
		}
	}

	private void function validateEngineSettings( required struct settings ){
		if ( !isArray( arguments.settings.engines ) ) {
			throw(
				type    = "BuildConfig",
				message = "build.json engines must be an array like "
					& "[ { ""name"": ""Lucee 6"", ""configFile"": ""server-lucee@6.json"" } ]."
			);
		}
		for ( var engine in arguments.settings.engines ) {
			if ( !isStruct( engine ) || !structKeyExists( engine, "configFile" ) ) {
				throw(
					type    = "BuildConfig",
					message = "Every entry in build.json engines needs a configFile, for example "
						& "{ ""name"": ""Lucee 6"", ""configFile"": ""server-lucee@6.json"" }."
				);
			}
		}
	}

	private void function validateWarmupSettings( required struct settings ){
		if (
			!isStruct( arguments.settings.warmup )
			|| !isNumeric( arguments.settings.warmup.attempts ?: "" )
			|| !isNumeric( arguments.settings.warmup.delaySeconds ?: "" )
		) {
			throw( type = "BuildConfig", message = "build.json warmup must look like { ""attempts"": 60, ""delaySeconds"": 5 }." );
		}
	}

	private void function validateTestRunner( required struct settings ){
		if ( !reFindNoCase( "^https?://", arguments.settings.testRunner ) ) {
			throw(
				type    = "BuildConfig",
				message = "build.json testRunner must be a full URL, for example "
					& """http://127.0.0.1:60310/tests/runner.cfm""."
			);
		}
	}

	/**
	 * Return the final exclusion list. It contains excludes followed by excludesAdd.
	 */
	array function allExcludes(){
		var result = duplicate( variables.settings.excludes );
		result.append( variables.settings.excludesAdd, true );
		return result;
	}

	/**
	 * Return the site root used for the test-server check. Do not return the test runner URL because
	 * requesting that URL would start the full test suite.
	 */
	string function probeUrl(){
		return reReplaceNoCase( variables.settings.testRunner, "^(https?://[^/]+).*$", "\1" ) & "/";
	}
}
