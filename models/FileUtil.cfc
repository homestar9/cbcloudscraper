/**
 * Small file and directory helpers shared by this module's models.
 *
 * These exist so the same code is not copied into several components. ModuleConfig.cfc keeps
 * its own copy of makeDirectory() because onLoad() runs before WireBox can build a model.
 */
component singleton {

	function init(){
		return this;
	}

	/**
	 * Create a directory and any missing parents.
	 *
	 * java.io.File.mkdirs() is used instead of directoryCreate() because Adobe ColdFusion accepts
	 * only the path argument, and Lucee's extra arguments make the file fail to compile on Adobe -
	 * even on a line that never runs.
	 *
	 * @path The directory to create.
	 *
	 * @return True when the directory exists after this call.
	 */
	boolean function makeDirectory( required string path ){
		if ( directoryExists( arguments.path ) ) {
			return true;
		}
		return createObject( "java", "java.io.File" ).init( javacast( "string", arguments.path ) ).mkdirs();
	}

}
