/**
 * File and directory helpers shared by this module's models.
 *
 * ModuleConfig.cfc keeps its own makeDirectory() method. Its onLoad() method runs before WireBox
 * can create this component.
 */
component singleton {

	function init(){
		return this;
	}

	/**
	 * Create a directory and any missing parents.
	 *
	 * Use java.io.File.mkdirs() because directoryCreate() differs between CFML engines. Adobe
	 * ColdFusion accepts only the path argument. Lucee-only arguments cause a compile error on
	 * Adobe, even when the code is in a branch that does not run.
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
