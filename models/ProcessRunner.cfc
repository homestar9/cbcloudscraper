/**
 * Runs the cbcloudscraper executable and reports the result.
 *
 * This component uses Java's ProcessBuilder instead of cfexecute. The supported CFML engines
 * do not handle cfexecute in the same way. Depending on the engine, cfexecute may lose the exit
 * code, leave a timed-out process running, or read output with the wrong character set.
 * ProcessBuilder handles these cases the same way on Lucee, Adobe ColdFusion, and BoxLang.
 *
 * ProcessBuilder sends all console output to a diagnostic log file. This prevents a large
 * amount of output from filling the operating system's pipe buffer and freezing the JVM thread.
 * The executable writes the HTTP result to a separate response file.
 */
component singleton {

	/**
	 * Run the executable and wait for it to finish or time out.
	 *
	 * @command        The executable path followed by one array item for each argument. Paths with spaces do not need quotes.
	 * @logPath        File path where the child's combined output is written.
	 * @timeoutSeconds Maximum seconds to wait before the child is forcibly stopped.
	 * @env            Optional struct of extra environment variables for the child process.
	 * @workingDir     Optional working directory for the child process.
	 *
	 * @return A struct with the numeric exitCode, boolean timedOut, and string logPath values.
	 */
	struct function run(
		required array command,
		required string logPath,
		required numeric timeoutSeconds,
		struct env        = {},
		string workingDir = ""
	){
		var jFile     = createObject( "java", "java.io.File" );
		var jTimeUnit = createObject( "java", "java.util.concurrent.TimeUnit" );

		// Use a Java string list so every CFML engine selects the ProcessBuilder(List) constructor.
		var cmdList = createObject( "java", "java.util.ArrayList" ).init();
		for ( var token in arguments.command ) {
			cmdList.add( javacast( "string", token ) );
		}

		var builder = createObject( "java", "java.lang.ProcessBuilder" ).init( cmdList );
		builder.redirectErrorStream( javacast( "boolean", true ) );
		builder.redirectOutput( jFile.init( arguments.logPath ) );

		if ( len( arguments.workingDir ) ) {
			builder.directory( jFile.init( arguments.workingDir ) );
		}

		if ( structCount( arguments.env ) ) {
			var environment = builder.environment();
			for ( var key in arguments.env ) {
				environment.put( javacast( "string", key ), javacast( "string", arguments.env[ key ] ) );
			}
		}

		var process  = builder.start();
		var finished = process.waitFor( javacast( "long", arguments.timeoutSeconds ), jTimeUnit.SECONDS );

		if ( !finished ) {
			// Force the process to stop, then wait briefly for the operating system to finish the shutdown.
			process.destroyForcibly();
			process.waitFor( javacast( "long", 5 ), jTimeUnit.SECONDS );
			return {
				"exitCode" : -1,
				"timedOut" : true,
				"logPath"  : arguments.logPath
			};
		}

		return {
			"exitCode" : process.exitValue(),
			"timedOut" : false,
			"logPath"  : arguments.logPath
		};
	}

}
