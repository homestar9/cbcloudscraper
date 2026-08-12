/**
 * Runs the project test suite on each configured CFML engine.
 *
 * Run `box run-script test:engines` from the project root. Add the engine names and server JSON
 * files to build/build.json first. The engines run one at a time because they share one port.
 *
 * The task stops old servers before starting the first engine. For each engine, it waits for the
 * site, runs the suite, and stops the server. Every engine runs even when an earlier engine fails.
 * After all engines finish, the task prints every result and returns an error if any engine failed.
 */
component {

	/** Load the shared settings. */
	function init(){
		variables.config   = new BuildConfig( getDirectoryFromPath( getCurrentTemplatePath() ) );
		variables.settings = variables.config.getSettings();
		return this;
	}

	/**
	 * Run the suite on each engine. Continue after a failed engine so the final report includes
	 * every result. Return an error after the report if any engine failed. This error stops CI and
	 * release tasks. Stop every server before this method ends.
	 */
	function run(){
		if ( !arrayLen( variables.settings.engines ) ) {
			return fail(
				"No engines are listed in build/build.json.",
				[
					'"engines": [',
					'    { "name": "Lucee 5",    "configFile": "server-lucee@5.json" },',
					'    { "name": "Adobe 2023", "configFile": "server-adobe@2023.json" }',
					']',
					"",
					"Each configFile is a server json file in your project root.",
					"Every engine you list is run, in the order you list them."
				],
				"Add them to build/build.json like this"
			);
		}

		var results = [];
		var started = getTickCount();

		// Stop all configured servers because only one server can use the shared port.
		stopAllEngines();

		for ( var engine in variables.settings.engines ) {
			results.append( runEngine( engine ) );
		}

		return report( results, started );
	}

	// Engine workflow

	private struct function runEngine( required struct engine ){
		var engineName  = arguments.engine.name ?: arguments.engine.configFile;
		var engineStart = getTickCount();
		print.line().boldBlueLine( "=== #engineName# (#arguments.engine.configFile#) ===" ).toConsole();

		var startResult = startEngine( arguments.engine, engineName );
		if ( !startResult.ok ) {
			return recordFailure( engineName, engineStart, startResult.reason );
		}

		var warmUpResult = warmUp( arguments.engine, engineName );
		if ( !warmUpResult.ok ) {
			return recordFailure( engineName, engineStart, warmUpResult.reason );
		}

		var suiteFailed = runTestSuite( engineName );
		stopEngine( arguments.engine.configFile );
		if ( suiteFailed ) {
			return recordFailure( engineName, engineStart, "the suite failed" );
		}

		return recordSuccess( engineName, engineStart );
	}

	private boolean function runTestSuite( required string engineName ){
		print.blueLine( "Running the suite on #arguments.engineName#..." ).toConsole();
		try {
			command( "testbox run" )
				.params( runner = variables.settings.testRunner, verbose = false )
				.run();
			return shell.getExitCode() != 0;
		} catch ( any ignoredException ) {
			return true;
		}
	}

	/**
	 * Start one engine's server. Return ok and reason values instead of stopping the task. The task
	 * can then record a startup failure and continue to the next engine.
	 *
	 * @engine     The engine entry from build.json.
	 * @engineName The name to show.
	 */
	private struct function startEngine( required struct engine, required string engineName ){
		// Wait for the old server to release the port. The stop command can return before the
		// operating system releases it, which would cause an unrelated startup failure.
		waitForPortToFree( arguments.engineName );

		var startFailed = false;
		var startError  = "";
		try {
			command( "server start" )
				.params( serverConfigFile = arguments.engine.configFile )
				.run();
			startFailed = ( shell.getExitCode() != 0 );
		} catch ( any exception ) {
			startFailed = true;
			startError  = exception.message;
		}
		if ( startFailed ) {
			print
				.line()
				.boldLine( "Why a server will not start, usually:" )
				.yellowLine( "  the file is missing from your project root" )
				.yellowLine( "  another server still holds the port" )
				.yellowLine( "  the engine could not be downloaded" )
				.line()
				.boldLine( "Try it by hand to see the real reason:" )
				.yellowLine( "  box server start serverConfigFile=#arguments.engine.configFile#" )
				.line()
				.toConsole();
			// A failed start may still hold the port. Stop that server before trying the next engine.
			stopEngine( arguments.engine.configFile );
			return {
				"ok"     : false,
				"reason" : "would not start" & ( len( startError ) ? ": " & startError : "" )
			};
		}

		return { "ok" : true, "reason" : "" };
	}

	/**
	 * Wait until the previous server releases the test port. Stop waiting after a short timeout.
	 * If the port is still busy, the next server command will return the specific startup error.
	 *
	 * @engineName The engine about to start, for the message.
	 */
	private function waitForPortToFree( required string engineName ){
		var probeUrl = variables.config.probeUrl();
		for ( var attempt = 1; attempt <= 12; attempt++ ) {
			var answered = false;
			try {
				cfhttp(
					url          = probeUrl,
					method       = "GET",
					timeout      = 5,
					throwonerror = false,
					redirect     = false,
					result       = "local.probe"
				);
				answered = ( val( local.probe.statuscode ?: "0" ) > 0 );
			} catch ( any ignoredException ) {
				answered = false;
			}
			if ( !answered ) {
				return;
			}
			if ( attempt == 1 ) {
				print.yellowLine( "Waiting for the previous server to release the port..." ).toConsole();
			}
			sleep( 5000 );
		}
		print
			.yellowLine( "Something still answers on the port. Starting #arguments.engineName# anyway." )
			.toConsole();
	}

	/**
	 * Wait until the site responds before starting the test suite. Tests run during application
	 * startup can fail for reasons unrelated to the code. Return ok and reason values so the task
	 * can record the failure and continue to the next engine.
	 *
	 * @engine     The engine entry from build.json.
	 * @engineName The name to show.
	 */
	private struct function warmUp( required struct engine, required string engineName ){
		var attempts    = variables.settings.warmup.attempts;
		var delaySeconds = variables.settings.warmup.delaySeconds;
		var probeUrl    = variables.config.probeUrl();

		print.blueLine( "Waiting for #arguments.engineName# (up to #attempts * delaySeconds# seconds)..." ).toConsole();
		var lastStatus = 0;
		for ( var attempt = 1; attempt <= attempts; attempt++ ) {
			var httpResult = "";
			try {
				cfhttp(
					url          = probeUrl,
					method       = "GET",
					timeout      = 60,
					throwonerror = false,
					redirect     = false,
					result       = "local.httpResult"
				);
				lastStatus = val( httpResult.statuscode ?: "0" );
			} catch ( any ignoredException ) {
				lastStatus = 0;
			}
			// Any 2xx or 3xx status proves that the site responded.
			if ( lastStatus >= 200 && lastStatus < 400 ) {
				print.greenLine( "#arguments.engineName# is up (status #lastStatus#)." ).toConsole();
				return { "ok" : true, "reason" : "" };
			}
			sleep( delaySeconds * 1000 );
		}

		stopEngine( arguments.engine.configFile );
		print
			.line()
			.yellowLine(
				"A repeating 500 usually means the app will not start on this engine. Start it by hand and read the log:"
			)
			.yellowLine( "  box server start serverConfigFile=#arguments.engine.configFile#" )
			.line()
			.toConsole();

		return { "ok" : false, "reason" : "never answered (last status: #lastStatus#)" };
	}

	/**
	 * Try to stop every configured engine. Ignore failures because at most one server is running.
	 */
	private function stopAllEngines(){
		print.blueLine( "Stopping any running server..." ).toConsole();
		for ( var engine in variables.settings.engines ) {
			stopEngine( engine.configFile );
		}
	}

	/**
	 * Try to stop one server without printing an error. A failure means the server was not running
	 * or the next start command will report that the port is still busy.
	 *
	 * @configFile The server json file for the engine to stop.
	 */
	private function stopEngine( required string configFile ){
		try {
			command( "server stop" ).params( serverConfigFile = arguments.configFile ).run();
		} catch ( any ignoredException ) {
			// The server is already stopped.
		}
	}

	/**
	 * Build a failed result for one engine and print a short reason.
	 *
	 * @engineName  The name to show.
	 * @engineStart The tick count from when this engine's turn began.
	 * @reason      Why it failed, in a few words.
	 */
	private struct function recordFailure( required string engineName, required numeric engineStart, required string reason ){
		var minutes = numberFormat( ( getTickCount() - arguments.engineStart ) / 60000, "0.9" );
		print.boldRedLine( "#arguments.engineName#: FAILED after #minutes# min -- #arguments.reason#" ).toConsole();
		return {
			"name"    : arguments.engineName,
			"passed"  : false,
			"minutes" : minutes,
			"reason"  : arguments.reason
		};
	}

	private struct function recordSuccess( required string engineName, required numeric engineStart ){
		var minutes = numberFormat( ( getTickCount() - arguments.engineStart ) / 60000, "0.9" );
		print.boldGreenLine( "#arguments.engineName#: passed in #minutes# min." ).toConsole();
		return {
			"name"    : arguments.engineName,
			"passed"  : true,
			"minutes" : minutes,
			"reason"  : ""
		};
	}

	/**
	 * Print one result per engine. End with an error when any engine failed so CommandBox returns
	 * a failing exit code.
	 *
	 * @results One entry per engine, in the order they ran.
	 * @started The tick count from when the whole sweep began.
	 */
	private function report( required array results, required numeric started ){
		var totalMinutes = numberFormat( ( getTickCount() - arguments.started ) / 60000, "0.9" );
		var failedResults = arguments.results.filter( function( result ){
			return !result.passed;
		} );

		print.line().boldLine( "Results (#totalMinutes# min total):" ).toConsole();
		for ( var result in arguments.results ) {
			if ( result.passed ) {
				print.greenLine( "  PASSED  #result.name# (#result.minutes# min)" ).toConsole();
			} else {
				print.redLine( "  FAILED  #result.name# (#result.minutes# min) -- #result.reason#" ).toConsole();
			}
		}
		print.line().toConsole();

		if ( !failedResults.len() ) {
			print.boldGreenLine( "All #arguments.results.len()# engines passed." ).toConsole();
			return;
		}

		var failedNames = failedResults.map( function( result ){
			return result.name;
		} );

		return error(
			"#failedResults.len()# of #arguments.results.len()# engines failed: "
			& failedNames.toList( ", " ) & "."
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
}
