/**
 * Tests the CloudScraper model.
 *
 * Most tests inject MockRunner, so they work on any CFML engine and operating system without the
 * real executable. They cover request building, response decoding, headers, cookies, and process
 * failures. The final test uses the real executable and is skipped when that file is not built.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	function beforeAll(){
		super.beforeAll();
	}

	function afterAll(){
		super.afterAll();
	}

	function run(){
		// Check the default Windows build path before enabling the live executable test.
		var hasBinary = fileExists( expandPath( "/cbcloudscraper/bin/win64/cbcloudscraper.exe" ) );

		describe( "CloudScraper", function(){
			var cs         = "";
			var mockRunner = "";
			var realRunner = "";
			var tempDir    = "";

			beforeEach( function(){
				cs         = getInstance( "CloudScraper@cbcloudscraper" );
				realRunner = cs.getRunner(); // Save the real runner so afterEach() can restore it.
				mockRunner = new tests.resources.MockRunner();
				cs.setRunner( mockRunner ); // Prevent unit tests from starting the real executable.

				// Give each test its own download directory.
				tempDir = replace( getTempDirectory(), "\", "/", "all" );
				tempDir = reReplace( tempDir, "/$", "" ) & "/cbcs-spec-" & createUUID();
				createObject( "java", "java.io.File" ).init( javacast( "string", tempDir ) ).mkdirs();
			} );

			afterEach( function(){
				// CloudScraper is a singleton. Restore the runner so this test cannot affect later tests.
				cs.setRunner( realRunner );
				if ( len( tempDir ) && directoryExists( tempDir ) ) {
					directoryDelete( tempDir, true );
				}
			} );

			it( "returns a decoded body, status, headers and cookies on success", function(){
				var result = cs.get( "https://example.com" );

				expect( result.ok ).toBeTrue();
				expect( result.statusCode ).toBe( 200 );
				expect( result.engineUsed ).toBe( "curl_cffi" );
				expect( result.fileContent ).toBe( "Hello, cbcloudscraper!" );
				expect( result.charset ).toBe( "utf-8" );

				// Check the simple header struct and the complete ordered header list.
				expect( result.headers ).toHaveKey( "Content-Type" );
				expect( result.rawHeaders.len() ).toBe( 2 );

				expect( result.cookies.len() ).toBe( 1 );
				expect( result.cookies[ 1 ].name ).toBe( "cf_clearance" );
			} );

			it( "sends the method, engine, and a URL-encoded form body for post()", function(){
				cs.post(
					url     = "https://example.com/submit",
					body    = { "a" : "1", "b" : "2" },
					options = { "engine" : "curl_cffi" }
				);

				var sent = mockRunner.getLastRequest();
				expect( sent.method ).toBe( "POST" );
				expect( sent.engine ).toBe( "curl_cffi" );

				var decodedBody = charsetEncode( binaryDecode( sent.bodyBase64, "base64" ), "utf-8" );
				expect( decodedBody ).toInclude( "a=1" );
				expect( decodedBody ).toInclude( "b=2" );
			} );

			it( "applies per-request options and extra headers", function(){
				cs.get(
					url     = "https://example.com",
					options = {
						"timeout"     : 15,
						"impersonate" : "chrome131",
						"headers"     : { "X-Test" : "yes" }
					}
				);

				var sent = mockRunner.getLastRequest();
				expect( sent.timeoutSeconds ).toBe( 15 );
				expect( sent.impersonate ).toBe( "chrome131" );
				expect( sent.headers[ "X-Test" ] ).toBe( "yes" );
			} );

			it( "returns ok=false with a timeout message when the process times out", function(){
				mockRunner.setBehavior( "timeout" );
				var result = cs.get( "https://example.com" );

				expect( result.ok ).toBeFalse();
				expect( result.statusCode ).toBe( 0 );
				expect( result.errorDetail ).toInclude( "timeout" );
				// A failure result keeps the same types as a success result.
				expect( isBinary( result.fileContentAsBinary ) ).toBeTrue();
			} );

			it( "returns ok=false when no response file is produced", function(){
				mockRunner.setBehavior( "noFile" );
				var result = cs.get( "https://example.com" );

				expect( result.ok ).toBeFalse();
				expect( result.errorDetail ).toInclude( "no response" );
			} );

			it( "returns ok=false when the worker reports an error", function(){
				mockRunner.setBehavior( "errorResponse" );
				var result = cs.get( "https://example.com" );

				expect( result.ok ).toBeFalse();
				expect( result.errorDetail ).toInclude( "boom" );
			} );

			it( "returns ok=false when the response is malformed", function(){
				mockRunner.setBehavior( "malformed" );
				var result = cs.get( "https://example.com" );

				expect( result.ok ).toBeFalse();
				expect( len( result.errorDetail ) ).toBeGT( 0 );
			} );

			it( "throws when throwOnError is set and an operational error occurs", function(){
				mockRunner.setBehavior( "timeout" );
				expect( function(){
					cs.get( url = "https://example.com", options = { "throwOnError" : true } );
				} ).toThrow( type = "cbcloudscraper.RequestException" );
			} );

			it( "returns ok=false when an explicitly set binary path does not exist", function(){
				var settings        = getInstance( dsl = "coldbox:moduleSettings:cbcloudscraper" );
				var original        = settings.binaryPath;
				settings.binaryPath = "Z:/does/not/exist/cbcloudscraper.exe";
				try {
					var result = cs.get( "https://example.com" );
					expect( result.ok ).toBeFalse();
					expect( result.errorDetail ).toInclude( "does not exist" );
				} finally {
					settings.binaryPath = original;
				}
			} );

			it( "does not decode the body to text when decodeText is false", function(){
				var result = cs.get( url = "https://example.com", options = { "decodeText" : false } );

				expect( result.ok ).toBeTrue();
				expect( result.fileContent ).toBe( "" );
				// decodeText skips the string copy but keeps the binary body.
				expect( isBinary( result.fileContentAsBinary ) ).toBeTrue();
				expect( charsetEncode( result.fileContentAsBinary, "utf-8" ) ).toBe( "Hello, cbcloudscraper!" );
			} );

			describe( "downloadTo", function(){
				it( "sends the target, the part path, and the longer download timeout", function(){
					var target = tempDir & "/report.csv";
					cs.get( url = "https://example.com/report.csv", options = { "downloadTo" : target } );

					var sent = mockRunner.getLastRequest();
					expect( sent.downloadTo ).toBe( target );
					expect( sent.downloadOnlyOn2xx ).toBeTrue();
					// Use defaultDownloadTimeout instead of the normal request timeout.
					expect( sent.timeoutSeconds ).toBe( 300 );
					// Keep the .part file beside the target so the final rename can be atomic.
					expect( sent.downloadPartPath ).toInclude( target & ".cbcs-" );
					expect( sent.downloadPartPath ).toEndWith( ".part" );
				} );

				it( "lets an explicit timeout win over the download default", function(){
					cs.get(
						url     = "https://example.com/report.csv",
						options = { "downloadTo" : tempDir & "/report.csv", "timeout" : 45 }
					);

					expect( mockRunner.getLastRequest().timeoutSeconds ).toBe( 45 );
				} );

				it( "writes the file and skips both body copies on success", function(){
					var target = tempDir & "/report.csv";
					mockRunner.setDownloadBody( charsetDecode( "a,b#chr( 13 )##chr( 10 )#1,2", "utf-8" ) );

					var result = cs.get(
						url     = "https://example.com/report.csv",
						options = { "downloadTo" : target }
					);

					expect( result.ok ).toBeTrue();
					expect( result.downloadedTo ).toBe( target );
					expect( result.bytesWritten ).toBe( 8 );
					expect( fileExists( target ) ).toBeTrue();
					expect( fileRead( target, "utf-8" ) ).toBe( "a,b#chr( 13 )##chr( 10 )#1,2" );

					// A file download returns an empty string and empty binary value for the body.
					expect( result.fileContent ).toBe( "" );
					expect( isBinary( result.fileContentAsBinary ) ).toBeTrue();
					// Every supported CFML engine encodes an empty byte array as an empty string.
					expect( binaryEncode( result.fileContentAsBinary, "base64" ) ).toBe( "" );
				} );

				it( "leaves the target file alone when the site returns an error", function(){
					var target = tempDir & "/report.csv";
					fileWrite( target, "yesterday's good data" );
					// Compare the file contents before and after the request. Adobe ColdFusion 2025
					// adds a line ending when fileWrite() receives a string. Comparing with the
					// original string would fail only on Adobe ColdFusion.
					var before = fileRead( target, "utf-8" );
					mockRunner.setBehavior( "downloadError" );

					var result = cs.get(
						url     = "https://example.com/report.csv",
						options = { "downloadTo" : target }
					);

					expect( result.statusCode ).toBe( 403 );
					expect( result.downloadedTo ).toBe( "" );
					expect( result.bytesWritten ).toBe( 0 );
					expect( fileRead( target, "utf-8" ) ).toBe( before );
					expect( before ).toInclude( "yesterday's good data" );
					// Return the error page in memory so the caller can inspect it.
					expect( result.fileContent ).toInclude( "Forbidden" );
				} );

				it( "writes the file itself when the helper executable is out of date", function(){
					var target = tempDir & "/report.csv";
					mockRunner.setBehavior( "oldHelper" );

					var result = cs.get(
						url     = "https://example.com/report.csv",
						options = { "downloadTo" : target }
					);

					// Keep the same result shape used by workers that support downloads.
					expect( result.downloadedTo ).toBe( target );
					expect( result.bytesWritten ).toBe( 22 );
					expect( fileRead( target, "utf-8" ) ).toBe( "Hello, cbcloudscraper!" );
					expect( result.fileContent ).toBe( "" );
					expect( binaryEncode( result.fileContentAsBinary, "base64" ) ).toBe( "" );
				} );

				it( "deletes the in-progress file when the request fails", function(){
					var target = tempDir & "/report.csv";
					mockRunner.setBehavior( "partialThenFail" );

					var result = cs.get(
						url     = "https://example.com/report.csv",
						options = { "downloadTo" : target }
					);

					expect( result.ok ).toBeFalse();
					expect( result.downloadedTo ).toBe( "" );

					var leftovers = directoryList( tempDir, false, "name", "*.part" );
					expect( leftovers.len() ).toBe( 0 );
				} );

				it( "deletes an in-progress file left behind by an earlier run", function(){
					var target = tempDir & "/report.csv";
					var stale  = target & ".cbcs-deadbeef.part";
					var fresh  = target & ".cbcs-c0ffee00.part";
					fileWrite( stale, "left over after a crash" );
					fileWrite( fresh, "another download is running" );
					// Make the stale file three hours old so it is past the cleanup cutoff. Use Java
					// because CFML engines use different functions to set a file timestamp.
					var threeHoursAgo = createObject( "java", "java.lang.System" ).currentTimeMillis() - 10800000;
					createObject( "java", "java.io.File" )
						.init( javacast( "string", stale ) )
						.setLastModified( javacast( "long", threeHoursAgo ) );

					cs.get( url = "https://example.com/report.csv", options = { "downloadTo" : target } );

					expect( fileExists( stale ) ).toBeFalse();
					expect( fileExists( fresh ) ).toBeTrue();
				} );

				it( "throws when downloadTo is not an absolute path", function(){
					expect( function(){
						cs.get(
							url     = "https://example.com/report.csv",
							options = { "downloadTo" : "data/report.csv" }
						);
					} ).toThrow( type = "cbcloudscraper.InvalidOption" );
				} );

				it( "throws when downloadTo names an existing directory", function(){
					expect( function(){
						cs.get( url = "https://example.com/report.csv", options = { "downloadTo" : tempDir } );
					} ).toThrow( type = "cbcloudscraper.InvalidOption" );
				} );

				it( "creates a parent directory that does not exist yet", function(){
					var target = tempDir & "/reports/2026/august/report.csv";

					var result = cs.get(
						url     = "https://example.com/report.csv",
						options = { "downloadTo" : target }
					);

					expect( result.downloadedTo ).toBe( target );
					expect( fileExists( target ) ).toBeTrue();
				} );

				it( "uses the downloadOnlyOn2xx module setting, including a configured false", function(){
					// Adobe ColdFusion treats false as missing when ?: is used. The request must keep
					// the configured false value.
					var settings = getInstance( dsl = "coldbox:moduleSettings:cbcloudscraper" );
					var original = settings.downloadOnlyOn2xx;
					try {
						settings.downloadOnlyOn2xx = false;
						cs.get(
							url     = "https://example.com/report.csv",
							options = { "downloadTo" : tempDir & "/a.csv" }
						);
						expect( mockRunner.getLastRequest().downloadOnlyOn2xx ).toBeFalse();

						// The request option overrides the module setting.
						cs.get(
							url     = "https://example.com/report.csv",
							options = {
								"downloadTo"        : tempDir & "/b.csv",
								"downloadOnlyOn2xx" : true
							}
						);
						expect( mockRunner.getLastRequest().downloadOnlyOn2xx ).toBeTrue();
					} finally {
						settings.downloadOnlyOn2xx = original;
					}
				} );
			} );

			it(
				title = "fetches a live URL through the real binary (Windows, built binary only)",
				skip  = !hasBinary,
				body  = function(){
					// Use the real process runner for this integration test.
					cs.setRunner( getInstance( "ProcessRunner@cbcloudscraper" ) );

					var result = cs.get( "https://example.com" );

					expect( result.ok ).toBeTrue();
					expect( result.statusCode ).toBe( 200 );
					expect( result.fileContent ).toInclude( "Example Domain" );
					expect( result.engineUsed ).toBe( "curl_cffi" );
				}
			);

			it(
				title = "downloads to a file through the real binary (Windows, built binary only)",
				skip  = !hasBinary,
				body  = function(){
					cs.setRunner( getInstance( "ProcessRunner@cbcloudscraper" ) );
					var target = tempDir & "/example.html";

					var result = cs.get( url = "https://example.com", options = { "downloadTo" : target } );

					expect( result.ok ).toBeTrue();
					expect( result.statusCode ).toBe( 200 );
					expect( result.downloadedTo ).toBe( target );
					expect( result.bytesWritten ).toBeGT( 0 );
					expect( fileExists( target ) ).toBeTrue();
					expect( getFileInfo( target ).size ).toBe( result.bytesWritten );
					expect( fileRead( target, "utf-8" ) ).toInclude( "Example Domain" );
					// A file download returns no body text to CFML.
					expect( result.fileContent ).toBe( "" );
				}
			);
		} );
	}

}
