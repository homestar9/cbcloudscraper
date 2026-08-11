/**
 * Manages the on-disk cookie files that let Cloudflare clearance cookies persist
 * between separate runs of the executable.
 *
 * Each HTTP request runs the executable as its own process, so there is no shared
 * memory to hold a session. A Cloudflare clearance cookie (cf_clearance) earned on one
 * request is valuable on the next request to the same site. This component decides where
 * each site's cookie file lives and offers helpers to inspect or clear it. The executable
 * reads and writes the file itself; this component only manages paths and housekeeping.
 */
component singleton {

	property name="settings" inject="coldbox:moduleSettings:cbcloudscraper";

	/**
	 * Return the cookie file path for a domain, or an empty string when the cookie
	 * cache is turned off. An empty string tells the caller not to use a cookie file.
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

	/************************* PRIVATE HELPERS *************************/

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
	 * Turn a host name into a safe, short, unique file name. Keeps a readable prefix of
	 * the host and appends a hash so that unusual characters or very long names cannot
	 * produce an illegal or colliding file name.
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
