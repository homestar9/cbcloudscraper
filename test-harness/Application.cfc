/**
 * Starts the ColdBox application used by the browser-based test harness.
 *
 * Copyright 2005-2007 ColdBox Framework by Luis Majano and Ortus Solutions, Corp.
 */
component{

	// Module loaded by this test harness
	request.MODULE_NAME = "cbcloudscraper";

	// CFML application settings
	this.name              = hash( getCurrentTemplatePath() );
	this.sessionManagement = true;
	this.sessionTimeout    = createTimeSpan(0,0,15,0);
    this.setClientCookies  = true;

	// Lucee settings
	// Buffer function and tag output so Lucee can include it in exception details.
	this.bufferOutput 					= true;
	// Keep response compression off in the test harness.
	this.compression 					= false;
	// Use Lucee's smart whitespace handling.
	this.whiteSpaceManagement 			= "smart";
	// Keep whitespace in responses from remote CFC methods.
	this.suppressRemoteComponentContent = false;

	// ColdBox uses this directory as the test harness application root.
	COLDBOX_APP_ROOT_PATH       = getDirectoryFromPath( getCurrentTemplatePath() );
	// Leave empty because this test harness runs at the web root.
	COLDBOX_APP_MAPPING         = "";
	// Use ColdBox's default configuration file.
	COLDBOX_CONFIG_FILE 	    = "";
	// Use ColdBox's default application key.
	COLDBOX_APP_KEY 		    = "";

	// Map /root to the test harness directory.
	this.mappings[ "/root" ] = COLDBOX_APP_ROOT_PATH;

	// Find the module directory and the directory that contains it.
	moduleRootPath 	= REReplaceNoCase( this.mappings[ "/root" ], "#request.MODULE_NAME#(\\|/)test-harness(\\|/)", "" );
	modulePath 		= REReplaceNoCase( this.mappings[ "/root" ], "test-harness(\\|/)", "" );

	// Add mappings used by the module and tests.
	this.mappings[ "/moduleroot" ] = moduleRootPath;
	this.mappings[ "/#request.MODULE_NAME#" ] = modulePath;

	// Optional ORM settings for modules that need a database
	//this.datasource = "coolblog";
	//this.ormEnabled = "true";
	/**
	this.ormSettings = {
		cfclocation = [ "models" ],
		logSQL = true,
		dbcreate = "update",
		secondarycacheenabled = false,
		cacheProvider = "ehcache",
		flushAtRequestEnd = false,
		eventhandling = true,
		eventHandler = "cborm.models.EventHandler",
		skipcfcWithError = true
	};
	**/

	// Start ColdBox when the CFML application starts.
	public boolean function onApplicationStart(){
		application.cbBootstrap = new coldbox.system.Bootstrap( COLDBOX_CONFIG_FILE, COLDBOX_APP_ROOT_PATH, COLDBOX_APP_KEY, COLDBOX_APP_MAPPING );
		application.cbBootstrap.loadColdbox();
		return true;
	}

	// Pass each request to ColdBox.
	public boolean function onRequestStart(String targetPage){

		if( url.keyExists( "fwreinit" ) ){
			if( server.keyExists( "lucee" ) ){
				pagePoolClear();
			}
			// Enable this call when tests use ORM and need a fresh configuration.
			// ormReload();
		}

		// Let ColdBox process the requested page.
		application.cbBootstrap.onRequestStart( arguments.targetPage );

		return true;
	}

	public void function onSessionStart(){
		application.cbBootStrap.onSessionStart();
	}

	public void function onSessionEnd( struct sessionScope, struct appScope ){
		arguments.appScope.cbBootStrap.onSessionEnd( argumentCollection=arguments );
	}

	public boolean function onMissingTemplate( template ){
		return application.cbBootstrap.onMissingTemplate( argumentCollection=arguments );
	}

}
