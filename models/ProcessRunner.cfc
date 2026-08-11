/**
 * Runs the cbcloudscraper executable once and reports how it finished.
 *
 * This uses Java's ProcessBuilder instead of the cfexecute tag on purpose. Across the
 * engines this module supports (Lucee, Adobe ColdFusion, BoxLang), cfexecute does not
 * reliably return the child's exit code, does not always kill the child when it times
 * out, and reads the child's output with the wrong character set. ProcessBuilder is the
 * same Java class on every engine and handles all three correctly.
 *
 * The child's own output (its diagnostic log) is redirected to a file so a large or
 * chatty child process cannot fill an operating-system pipe buffer and freeze the JVM
 * thread. The real HTTP result is written by the worker to a separate response file, not
 * to standard output.
 */
component singleton {

	/**
	 * Run the executable and wait for it to finish or time out.
	 *
	 * @command        Executable path first, then each argument as its own array element (so spaces in paths need no quoting).
	 * @logPath        File path where the child's combined output is written.
	 * @timeoutSeconds Maximum seconds to wait before the child is forcibly stopped.
	 * @env            Optional struct of extra environment variables for the child process.
	 * @workingDir     Optional working directory for the child process.
	 *
	 * @return struct with keys: exitCode (numeric), timedOut (boolean), logPath (string).
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

		// Build the command as a java.util.List<String> so it matches the
		// ProcessBuilder(List) constructor unambiguously on every engine.
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
			// The child ran past the deadline. Kill it and briefly wait so it is fully
			// stopped and not left running in the background.
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
