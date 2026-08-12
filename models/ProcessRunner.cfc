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
 *
 * The finally block in run() stops the child process when it is still running. A CFML engine can
 * interrupt the request thread while waitFor() waits for the process. Without this cleanup, the
 * process could continue running after the request ends.
 */
component singleton {

	property name="logger" inject="logbox:logger:{this}";

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

		var process = builder.start();

		// Start with the result values for a timeout. Replace them if the process finishes normally.
		//
		// The return statement must stay after the try/finally block. Lucee 5 fails to compile this
		// method when the return is inside the try block and the finally block contains another
		// try/catch. Lucee reports the compiler failure as a NullPointerException without a line
		// number.
		var exitCode = -1;
		var timedOut = true;

		try {
			// getOutputStream() returns the Java stream connected to the child process's standard
			// input. The executable does not read that input, so close the stream now. Otherwise, its
			// operating system handle can remain open until the JVM removes the process object from
			// memory. A busy server can leave many of these operating system resources open.
			closeQuietly( process.getOutputStream() );

			if ( process.waitFor( javacast( "long", arguments.timeoutSeconds ), jTimeUnit.SECONDS ) ) {
				exitCode = process.exitValue();
				timedOut = false;
			} else {
				// Force the process to stop. Then wait briefly for the operating system to finish.
				process.destroyForcibly();
				process.waitFor( javacast( "long", 5 ), jTimeUnit.SECONDS );
			}
		} finally {
			// waitFor() throws InterruptedException when the CFML engine interrupts this request
			// thread. This can happen when the server times out a request or an administrator cancels
			// it. Stop the child before the caller releases its process slot. On a normal return, the
			// child has already stopped and isAlive() returns false.
			try {
				if ( process.isAlive() ) {
					process.destroyForcibly();
				}
			} catch ( any e ) {
				// Log the cleanup error without changing the current result or error.
				logger.debug( "cbcloudscraper could not stop the child process during cleanup: " & e.message );
			}
		}

		return {
			"exitCode" : exitCode,
			"timedOut" : timedOut,
			"logPath"  : arguments.logPath
		};
	}

	/**
	 * Close a Java stream without letting a close error stop the request.
	 *
	 * @closeable Any object with a close() method.
	 */
	private void function closeQuietly( required any closeable ){
		try {
			arguments.closeable.close();
		} catch ( any e ) {
			// The stream may already be closed because the child exited. Log the error and continue.
			logger.debug( "cbcloudscraper could not close the child process input stream: " & e.message );
		}
	}

}
