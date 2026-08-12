/**
 * Manages cookie files that are shared across separate runs of the executable.
 *
 * Each HTTP request starts a new process, so requests cannot share cookies in memory.
 * A cf_clearance cookie from one request may help the next request reach the same site.
 * This component creates a separate cookie-file path for each site. It can also read or delete
 * those files. The executable handles changes to the cookie data during a request.
 */
component singleton {

	property name="settings" inject="coldbox:moduleSettings:cbcloudscraper";

	/**
	 * Return the cookie-file path for a domain. Return an empty string when cookie caching is off.
	 *
	 * @domain The target host name, for example "www.example.com".
	 */
	string function pathFor( required string domain ){
		if ( !isCacheEnabled() ) {
			return "";
		}
		return fileFor( arguments.domain );
	}

	/**
	 * Delete the cookie file for one domain. Returns true when a file was removed.
	 *
	 * @domain The target host name.
	 */
	boolean function clearCookies( required string domain ){
		var path = fileFor( arguments.domain );
		if ( fileExists( path ) ) {
			fileDelete( path );
			return true;
		}
		return false;
	}

	/**
	 * Delete every stored cookie file. Returns the number of files removed.
	 */
	numeric function clearAllCookies(){
		var dir = getDirectory();
		if ( !directoryExists( dir ) ) {
			return 0;
		}
		var files = directoryList( dir, false, "path", "*.cookies.json" );
		files.each( function( item ){
			fileDelete( arguments.item );
		} );
		return files.len();
	}

	/**
	 * Return the cookies stored for a domain as an array of structs, or an empty array.
	 *
	 * @domain The target host name.
	 */
	array function getCookies( required string domain ){
		var path = fileFor( arguments.domain );
		if ( !fileExists( path ) ) {
			return [];
		}
		try {
			return deserializeJSON( fileRead( path, "utf-8" ) );
		} catch ( any e ) {
			return [];
		}
	}

	// Private helpers

	private boolean function isCacheEnabled(){
		return structKeyExists( settings, "cookieCache" ) && ( settings.cookieCache.enabled ?: false );
	}

	private string function fileFor( required string domain ){
		return getDirectory() & "/" & sanitize( arguments.domain ) & ".cookies.json";
	}

	private string function getDirectory(){
		var dir = ( structKeyExists( settings, "cookieCache" ) ? ( settings.cookieCache.directory ?: "" ) : "" );
		if ( !len( dir ) ) {
			dir = settings.workingDirectory & "/cookies";
		}
		if ( !directoryExists( dir ) ) {
			directoryCreate( dir, true, true );
		}
		return dir;
	}

	/**
	 * Build a safe cookie filename from a host name. Keep the first 40 valid characters so the
	 * file remains recognizable. Add a hash so different host names cannot use the same file.
	 */
	private string function sanitize( required string domain ){
		var host = lCase(
			reReplace(
				arguments.domain,
				"[^a-zA-Z0-9\.\-]",
				"",
				"all"
			)
		);
		if ( !len( host ) ) {
			host = "unknown";
		}
		return left( host, 40 ) & "-" & lCase( hash( arguments.domain, "MD5" ) );
	}

}
