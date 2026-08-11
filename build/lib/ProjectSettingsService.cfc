/**
 * Calculates project settings used by BuildConfig.cfc and Install.cfc.
 *
 * This component does not read or write files. Callers provide parsed JSON and filenames.
 */
component {

	/**
	 * Returns "module" for installable CommandBox package types. Returns "app" otherwise.
	 */
	string function detectProjectType( required struct packageData ){
		var packageType = lCase( arguments.packageData.type ?: "" );
		var moduleTypes = "modules,commandbox-modules,cachebox-modules,logbox-modules,wirebox-modules,plugins,interceptors";
		return listFindNoCase( moduleTypes, packageType ) ? "module" : "app";
	}

	/**
	 * Returns the first test runner URL from box.json or the standard local fallback.
	 */
	string function detectTestRunner( required struct packageData ){
		var configuredRunner = arguments.packageData.testbox.runner ?: "";

		if ( isArray( configuredRunner ) && arrayLen( configuredRunner ) ) {
			configuredRunner = isStruct( configuredRunner[ 1 ] )
				? ( configuredRunner[ 1 ].default ?: "" )
				: configuredRunner[ 1 ];
		} else if ( isStruct( configuredRunner ) ) {
			for ( var runnerName in configuredRunner ) {
				configuredRunner = configuredRunner[ runnerName ];
				break;
			}
		}

		return isSimpleValue( configuredRunner ) && len( trim( configuredRunner ) )
			? trim( configuredRunner )
			: "http://127.0.0.1:60299/tests/runner.cfm";
	}

	/**
	 * Returns BuildConfig.cfc's default package exclusions.
	 */
	array function buildConfigDefaultExcludes(){
		return [
			"^[\\/]?build$",
			"^[\\/]?modules$",
			"^[\\/]?node_modules$",
			"^[\\/]?test-harness$",
			"^[\\/]?tests$",
			"^[\\/]?test-results$",
			"server-.*\.json",
			"^[\\/]?temp$",
			"^[\\/]?plans$",
			"(AGENTS|CLAUDE|DEVNOTES|RELEASE)\.md",
			"\.bak$",
			"\.(zip|tar|tar\.gz|tgz|7z|rar)$",
			"^[\\/]?\..*"
		];
	}

	/**
	 * Returns the exclusions that Install.cfc writes for a new project.
	 */
	array function installerDefaultExcludes( required string projectType ){
		if ( arguments.projectType == "module" ) {
			return [
				"^build$",
				"^modules$",
				"^node_modules$",
				"^resources$",
				"^test-harness$",
				"^tests$",
				"^test-results$",
				"^temp$",
				"^plans$",
				"^(package|package-lock)\.json$",
				"^webpack\.config\.js$",
				"^(vite|vitest)\.config\.js$",
				"^docker-compose\.yml$",
				"^server(?:-.*)?\.json$",
				"^.*\.code-workspace$",
				"^(AGENTS|CLAUDE|DEVNOTES|RELEASE)\.md$",
				"\.bak$",
				"\.(zip|tar|tar\.gz|tgz|7z|rar)$",
				"^\..*"
			];
		}

		var applicationExcludes = [
			"^build$",
			"^node_modules$",
			"^test-harness$",
			"^tests$",
			"^test-results$",
			"^temp$",
			"^server(?:-.*)?\.json$",
			"^.*\.code-workspace$",
			"^(AGENTS|CLAUDE|DEVNOTES|RELEASE)\.md$",
			"\.bak$",
			"\.(zip|tar|tar\.gz|tgz|7z|rar)$"
		];
		applicationExcludes.append( "^\.(?!(?:htaccess|well-known)$).*" );
		return applicationExcludes;
	}

	/**
	 * Chooses a display name for one CommandBox server configuration.
	 */
	string function engineName( required string fileName, struct serverSettings = {} ){
		if (
			structKeyExists( arguments.serverSettings, "app" )
			&& isStruct( arguments.serverSettings.app )
			&& structKeyExists( arguments.serverSettings.app, "cfengine" )
			&& isSimpleValue( arguments.serverSettings.app.cfengine )
			&& len( trim( arguments.serverSettings.app.cfengine ) )
		) {
			return readableEngineName( trim( arguments.serverSettings.app.cfengine ) );
		}

		if (
			structKeyExists( arguments.serverSettings, "name" )
			&& isSimpleValue( arguments.serverSettings.name )
			&& len( trim( arguments.serverSettings.name ) )
		) {
			return trim( arguments.serverSettings.name );
		}

		var filenameStem = reReplaceNoCase( arguments.fileName, "^server-?", "" );
		filenameStem     = reReplaceNoCase( filenameStem, "\.json$", "" );
		return len( trim( filenameStem ) ) ? readableEngineName( filenameStem ) : "Server";
	}

	/**
	 * Converts an engine ID or filename stem into a readable display name.
	 */
	string function readableEngineName( required string value ){
		var readableName = reReplaceNoCase( arguments.value, "[-_]cfml\b", "" );
		readableName     = replace( readableName, "@", " ", "all" );
		readableName     = replace( readableName, "-", " ", "all" );

		var words = listToArray( readableName, " " );
		for ( var index = 1; index <= arrayLen( words ); index++ ) {
			words[ index ] = uCase( left( words[ index ], 1 ) )
				& mid( words[ index ], 2, len( words[ index ] ) );
		}
		return arrayToList( words, " " );
	}
}
