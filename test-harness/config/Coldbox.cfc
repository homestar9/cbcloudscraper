component{

	// Configure the ColdBox test application.
	function configure(){

		// Main ColdBox settings
		coldbox = {
			// Application name
			appName 				= "Module Tester",

			// Development settings
			reinitPassword			= "",
			handlersIndexAutoReload = true,
			modulesExternalLocation = [],

			// Optional application events
			defaultEvent			= "",
			requestStartHandler		= "",
			requestEndHandler		= "",
			applicationStartHandler = "",
			applicationEndHandler	= "",
			sessionStartHandler 	= "",
			sessionEndHandler		= "",
			missingTemplateHandler	= "",

			// Error handling
			exceptionHandler		= "",
			onInvalidEvent			= "",
			customErrorTemplate 	= "/coldbox/system/exceptions/Whoops.cfm",

			// Disable handler and event caching during tests.
			handlerCaching 			= false,
			eventCaching			= false
		};

		// Match local host names to the development environment. Add a method named after an
		// environment when that environment needs its own settings.
		environments = {
			development = "localhost,127\.0\.0\.1"
		};

		// Module loading rules
		modules = {
			// An empty include list allows all discovered modules.
			include = [],
			// An empty exclude list blocks no modules.
			exclude = []
		};

		// Register interceptors in the order they should run.
		interceptors = [
		];

		// LogBox settings
		logBox = {
			// Send logs to the console and a rolling file.
			appenders = {
				myConsole : { class : "ConsoleAppender" },
				files : {
					class="RollingFileAppender",
					properties = {
						filename = "tester", filePath="/#appMapping#/logs"
					}
				}
			},
			// Root logger
			root = { levelmax="DEBUG", appenders="*" },
			// Log ColdBox system messages at the info level.
			info = [ "coldbox.system" ]
		};

	}

	/**
	 * Load and activate the module under test.
	 */
	function afterAspectsLoad( event, interceptData, rc, prc ){

		controller.getModuleService()
			.registerAndActivateModule(
				moduleName 		= request.MODULE_NAME,
				invocationPath 	= "moduleroot"
			);

		// Restart the renderer so it includes helpers from the loaded module.
        controller.getRenderer().startup()
		// Tell interceptors to load any helper methods added by the module.
        controller.getInterceptorService().announce( "cbLoadInterceptorHelpers" )
	}

}
