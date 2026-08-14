/**
 * Tests BinaryDownloader methods that do not use outside services.
 *
 * These tests do not use the network. They build expected paths from the current operating
 * system, so the same tests work on Windows development machines and Linux CI runners. Test the
 * real download manually with a published GitHub Release.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	function beforeAll(){
		super.beforeAll();
	}

	function afterAll(){
		super.afterAll();
	}

	function run(){
		var moduleRoot    = expandPath( "/cbcloudscraper" );
		var moduleVersion = deserializeJSON( fileRead( expandPath( "/cbcloudscraper/box.json" ), "utf-8" ) ).version;

		// Create a directory and its parents. directoryCreate() with extra arguments
		// does not compile on Adobe ColdFusion, so use java.io.File.mkdirs() here.
		var makeDirs = function( required string path ){
			createObject( "java", "java.io.File" ).init( arguments.path ).mkdirs();
		};

		// Write a throwaway file and return its path with forward slashes.
		var tempFile = function( required string contents ){
			var path = replace(
				getTempDirectory() & "cbcs-spec-" & createUUID(),
				"\",
				"/",
				"all"
			);
			fileWrite( path, arguments.contents );
			return path;
		};

		describe( "BinaryDownloader", function(){
			var downloader = "";
			var platform   = "";

			beforeEach( function(){
				downloader = getInstance( "BinaryDownloader@cbcloudscraper" );
				platform   = downloader.getPlatform();
			} );

			it( "reports a self-consistent platform", function(){
				expect( platform.asset ).toBe( "cbcloudscraper-" & platform.dir & ".zip" );
				expect( platform.exe ).toInclude( "cbcloudscraper" );
			} );

			it( "derives the release base URL from box.json repository.url", function(){
				expect( downloader.deriveBaseURL( moduleRoot ) ).toBe( "https://github.com/homestar9/cbcloudscraper/releases/download" );
			} );

			it( "uses an override base URL and trims a trailing slash", function(){
				expect( downloader.deriveBaseURL( moduleRoot, "https://example.com/dl/" ) ).toBe( "https://example.com/dl" );
			} );

			it( "resolves the release tag from the module version, or an override", function(){
				expect( downloader.resolveTag( moduleRoot ) ).toBe( "v" & moduleVersion );
				expect( downloader.resolveTag( moduleRoot, "v9.9.9" ) ).toBe( "v9.9.9" );
			} );

			it( "reads the module version from box.json", function(){
				expect( downloader.readModuleVersion( moduleRoot ) ).toBe( moduleVersion );
			} );

			it( "reports presence, stamp, and currency for a cached binary", function(){
				var dir     = getTempDirectory() & "cbcs-dl-" & createUUID();
				var platDir = dir & "/" & platform.dir;
				try {
					// A new directory has no executable or version tag.
					expect( downloader.isPresent( dir ) ).toBeFalse();
					expect( downloader.installedTag( dir ) ).toBe( "" );
					expect( downloader.isCurrent( dir, "v1.0.0" ) ).toBeFalse();

					// An executable without a version tag is treated as a local build and can be used.
					makeDirs( platDir );
					fileWrite( platDir & "/" & platform.exe, "not a real binary" );
					expect( downloader.isPresent( dir ) ).toBeTrue();
					expect( downloader.installedTag( dir ) ).toBe( "" );
					expect( downloader.isCurrent( dir, "v1.0.0" ) ).toBeTrue();

					// A tagged executable is current only when its tag matches the requested tag.
					fileWrite( platDir & "/.cbcloudscraper-version", "v1.0.0" );
					expect( downloader.installedTag( dir ) ).toBe( "v1.0.0" );
					expect( downloader.isCurrent( dir, "v1.0.0" ) ).toBeTrue();
					expect( downloader.isCurrent( dir, "v2.0.0" ) ).toBeFalse();
				} finally {
					directoryDelete( dir, true );
				}
			} );

			it( "builds the binary path from the base dir and platform", function(){
				var path = replace(
					downloader.binaryPathFor( "C:/tmp/base" ),
					"\",
					"/",
					"all"
				);
				expect( path ).toBe( "C:/tmp/base/" & platform.dir & "/" & platform.exe );
			} );

			it( "calls the progress callback only when the caller provides a function", function(){
				makePublic( downloader, "logMessage" );
				var messages = [];
				downloader.logMessage( function( message ){
					messages.append( arguments.message );
				}, "hello" );
				expect( messages ).toBe( [ "hello" ] );

				// The blank default and a non-function value are ignored without an error.
				downloader.logMessage( "", "ignored" );
				downloader.logMessage( { "not" : "a function" }, "ignored" );
				expect( messages.len() ).toBe( 1 );
			} );

			it( "sends a warning to onWarning, and to onProgress when there is no onWarning", function(){
				makePublic( downloader, "warn" );
				var warnings = [];
				var progress = [];
				var toWarn   = function( message ){
					warnings.append( arguments.message );
				};
				var toProgress = function( message ){
					progress.append( arguments.message );
				};

				downloader.warn( toWarn, toProgress, "careful" );
				expect( warnings ).toBe( [ "careful" ] );
				expect( progress ).toBeEmpty();

				// Without a warning callback the message still reaches the caller.
				downloader.warn( "", toProgress, "careful again" );
				expect( warnings.len() ).toBe( 1 );
				expect( progress ).toBe( [ "careful again" ] );
			} );
		} );

		describe( "BinaryDownloader.unzip", function(){
			var downloader = "";
			var workDir    = "";

			beforeEach( function(){
				downloader = getInstance( "BinaryDownloader@cbcloudscraper" );
				makePublic( downloader, "unzip" );
				workDir = replace(
					getTempDirectory() & "cbcs-unzip-" & createUUID(),
					"\",
					"/",
					"all"
				);
				makeDirs( workDir );
			} );

			afterEach( function(){
				if ( directoryExists( workDir ) ) {
					directoryDelete( workDir, true );
				}
			} );

			it( "unpacks a flat archive and keeps the file contents", function(){
				var zipPath = workDir & "/flat.zip";
				var target  = workDir & "/out";
				variables.writeZip(
					zipPath,
					[
						{ "name" : "readme.txt", "contents" : "hello" },
						{ "name" : "second.txt", "contents" : "world" }
					]
				);
				makeDirs( target );

				downloader.unzip( zipPath, target );

				expect( fileExists( target & "/readme.txt" ) ).toBeTrue();
				expect( fileRead( target & "/readme.txt", "utf-8" ) ).toBe( "hello" );
				expect( fileRead( target & "/second.txt", "utf-8" ) ).toBe( "world" );
			} );

			it( "creates folders for entries inside a nested path", function(){
				var zipPath = workDir & "/nested.zip";
				var target  = workDir & "/out";
				variables.writeZip( zipPath, [ { "name" : "lib/inner/data.txt", "contents" : "deep" } ] );
				makeDirs( target );

				downloader.unzip( zipPath, target );

				expect( directoryExists( target & "/lib/inner" ) ).toBeTrue();
				expect( fileRead( target & "/lib/inner/data.txt", "utf-8" ) ).toBe( "deep" );
			} );

			it( "handles folder entries named with backslashes", function(){
				// PowerShell's Compress-Archive writes entry names with backslashes, which the zip
				// format does not allow. Every release up to 1.1.0 was built that way, so an
				// archive like this has to keep working. Without handling it, the folder entry is
				// taken for a file and every entry inside that folder then fails to unpack.
				var zipPath = workDir & "/backslash.zip";
				var target  = workDir & "/out";
				variables.writeZip(
					zipPath,
					[
						{ "name" : "_internal\" },
						{ "name" : "_internal\crypto\" },
						{ "name" : "_internal\crypto\bindings.pyd", "contents" : "binary-ish" }
					]
				);
				makeDirs( target );

				downloader.unzip( zipPath, target );

				expect( directoryExists( target & "/_internal/crypto" ) ).toBeTrue();
				expect( fileRead( target & "/_internal/crypto/bindings.pyd", "utf-8" ) ).toBe( "binary-ish" );
			} );

			it( "reports a readable error when a directory cannot be created", function(){
				// A file and a folder cannot share a name. The old code let this surface as a bare
				// java.io.FileNotFoundException with no explanation.
				var zipPath = workDir & "/clash.zip";
				var target  = workDir & "/out";
				variables.writeZip(
					zipPath,
					[
						{ "name" : "thing", "contents" : "I am a file" },
						{ "name" : "thing/inside.txt", "contents" : "I need thing to be a folder" }
					]
				);
				makeDirs( target );

				expect( function(){
					downloader.unzip( zipPath, target );
				} ).toThrow( type = "cbcloudscraper.BinaryUnavailable", regex = "Could not create a directory" );
			} );

			it( "unpacks a file larger than the copy buffer without losing bytes", function(){
				var zipPath = workDir & "/big.zip";
				var target  = workDir & "/out";
				// The copy buffer is 64 KB. Use more than that so the read loop runs more than once.
				var big = repeatString( "abcdefghij", 20000 );
				variables.writeZip( zipPath, [ { "name" : "big.txt", "contents" : big } ] );
				makeDirs( target );

				downloader.unzip( zipPath, target );

				expect( getFileInfo( target & "/big.txt" ).size ).toBe( len( big ) );
				expect( fileRead( target & "/big.txt", "utf-8" ) ).toBe( big );
			} );

			it( "rejects an entry whose path escapes the target directory", function(){
				var zipPath = workDir & "/evil.zip";
				var target  = workDir & "/out";
				variables.writeZip( zipPath, [ { "name" : "../escaped.txt", "contents" : "no" } ] );
				makeDirs( target );

				expect( function(){
					downloader.unzip( zipPath, target );
				} ).toThrow( type = "cbcloudscraper.BinaryUnavailable" );

				expect( fileExists( workDir & "/escaped.txt" ) ).toBeFalse();
			} );
		} );

		describe( "BinaryDownloader.assertChecksum", function(){
			var downloader = "";

			beforeEach( function(){
				downloader = getInstance( "BinaryDownloader@cbcloudscraper" );
				makePublic( downloader, "assertChecksum" );
			} );

			// Nothing listens on port 1, so the checksum request fails right away. This keeps the
			// test off the network and off DNS, which a wildcard DNS or a proxy could interfere with.
			var deadURL = "http://127.0.0.1:1/asset.zip";

			it( "warns and continues when the published checksum cannot be read", function(){
				var fakeZip  = tempFile( "not a real archive" );
				var warnings = [];
				try {
					downloader.assertChecksum(
						zipURL    = deadURL,
						zipPath   = fakeZip,
						onWarning = function( message ){
							warnings.append( arguments.message );
						}
					);
					expect( warnings.len() ).toBe( 1 );
					expect( warnings[ 1 ] ).toInclude( "Skipping checksum verification" );
					// The download is kept, because warning is the default behavior.
					expect( fileExists( fakeZip ) ).toBeTrue();
				} finally {
					if ( fileExists( fakeZip ) ) {
						fileDelete( fakeZip );
					}
				}
			} );

			it( "throws and deletes the download when strictChecksum is on", function(){
				var fakeZip = tempFile( "not a real archive" );
				try {
					expect( function(){
						downloader.assertChecksum(
							zipURL         = deadURL,
							zipPath        = fakeZip,
							strictChecksum = true
						);
					} ).toThrow( type = "cbcloudscraper.BinaryUnavailable" );
					expect( fileExists( fakeZip ) ).toBeFalse();
				} finally {
					if ( fileExists( fakeZip ) ) {
						fileDelete( fakeZip );
					}
				}
			} );
		} );
	}

	/**
	 * Write a zip file containing the given entries.
	 *
	 * java.util.zip is used rather than cfzip so this test runs on a default Adobe ColdFusion
	 * install, which does not include the zip package.
	 *
	 * An array is used rather than a struct so an entry name keeps its exact spelling. A folder
	 * entry is any entry with no "contents" key; it is written with a length of zero.
	 *
	 * @zipPath Where to write the archive.
	 * @entries An array of structs, each with a name and optional contents.
	 */
	private void function writeZip( required string zipPath, required array entries ){
		var fileOut = createObject( "java", "java.io.FileOutputStream" ).init( javacast( "string", arguments.zipPath ) );
		var zipOut  = createObject( "java", "java.util.zip.ZipOutputStream" ).init( fileOut );
		try {
			for ( var entry in arguments.entries ) {
				zipOut.putNextEntry(
					createObject( "java", "java.util.zip.ZipEntry" ).init( javacast( "string", entry.name ) )
				);
				if ( structKeyExists( entry, "contents" ) ) {
					zipOut.write( javacast( "string", entry.contents ).getBytes( "UTF-8" ) );
				}
				zipOut.closeEntry();
			}
		} finally {
			zipOut.close();
			fileOut.close();
		}
	}

}
