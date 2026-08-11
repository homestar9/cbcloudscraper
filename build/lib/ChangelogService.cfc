/**
 * Reads and changes changelog text for the bump and release tasks.
 *
 * This component works with strings only. The task components check file paths and write the
 * returned text. Keeping file access outside this component makes every text rule easy to test.
 */
component {

	/**
	 * Moves the [Unreleased] notes into a dated version section.
	 *
	 * The returned text uses the same line endings as the input text.
	 *
	 * @content       The complete changelog text.
	 * @version       The version for the new section.
	 * @date          The release date in YYYY-MM-DD form.
	 * @changelogName The filename used in error messages.
	 */
	string function moveUnreleasedNotes(
		required string content,
		required string version,
		required string date,
		string changelogName = "CHANGELOG.md"
	){
		var usesWindowsLineEndings = arguments.content contains ( chr( 13 ) & chr( 10 ) );
		var lineFeed               = chr( 10 );
		var lines                  = listToArray(
			replace( arguments.content, chr( 13 ) & lineFeed, lineFeed, "all" ),
			lineFeed,
			true
		);

		var unreleasedIndex = findUnreleasedHeading( lines );
		if ( unreleasedIndex == 0 ) {
			throw(
				type    = "BuildChangelog.MissingUnreleased",
				message = "#arguments.changelogName# has no ""#### [Unreleased]"" section. Add one, put your notes under it, and run this again."
			);
		}

		var sectionEndIndex = findSectionEnd( lines, unreleasedIndex + 1 );
		var releaseNotes    = copyLines( lines, unreleasedIndex + 1, sectionEndIndex - 1 );
		trimBlankEdges( releaseNotes );

		if ( !arrayLen( releaseNotes ) ) {
			throw(
				type    = "BuildChangelog.EmptyUnreleased",
				message = "The ""#### [Unreleased]"" section in #arguments.changelogName# is empty. Write the release notes first."
			);
		}

		var outputLines = copyLines( lines, 1, unreleasedIndex );
		outputLines.append( "" );
		outputLines.append( "#### [" & arguments.version & "] - " & arguments.date );
		outputLines.append( "" );
		outputLines.append( releaseNotes, true );
		outputLines.append( "" );
		outputLines.append( copyLines( lines, sectionEndIndex, arrayLen( lines ) ), true );

		var outputLineEnding = usesWindowsLineEndings ? ( chr( 13 ) & lineFeed ) : lineFeed;
		return arrayToList( outputLines, outputLineEnding );
	}

	/**
	 * Returns the notes inside one dated version section.
	 *
	 * @content       The complete changelog text.
	 * @version       The version whose notes are needed.
	 * @changelogName The filename used in error messages.
	 */
	string function extractReleaseNotes(
		required string content,
		required string version,
		string changelogName = "CHANGELOG.md"
	){
		var lines         = listToArray( arguments.content, chr( 10 ), true );
		var collected     = [];
		var insideSection = false;

		for ( var rawLine in lines ) {
			var line      = reReplace( rawLine, chr( 13 ) & "$", "" );
			var isHeading = reFind( "^####\s*\[", line );

			if ( !insideSection && isHeading && line contains "[#arguments.version#]" ) {
				insideSection = true;
				continue;
			}

			if ( insideSection ) {
				if ( isSectionBoundary( line ) ) {
					break;
				}
				collected.append( line );
			}
		}

		if ( !insideSection ) {
			throw(
				type    = "BuildChangelog.MissingVersion",
				message = "#arguments.changelogName# has no ""#### [#arguments.version#]"" section. "
					& "Move your notes out of [Unreleased] into a dated section by running: "
					& "box run-script bump:patch"
			);
		}

		var releaseNotes = trim( arrayToList( collected, chr( 10 ) ) );
		if ( !len( releaseNotes ) ) {
			throw(
				type    = "BuildChangelog.EmptyVersion",
				message = "The ""#### [#arguments.version#]"" section in #arguments.changelogName# is empty. Write the notes first."
			);
		}

		return releaseNotes;
	}

	private numeric function findUnreleasedHeading( required array lines ){
		for ( var index = 1; index <= arrayLen( arguments.lines ); index++ ) {
			if ( reFindNoCase( "^####\s*\[Unreleased\]", arguments.lines[ index ] ) ) {
				return index;
			}
		}
		return 0;
	}

	private numeric function findSectionEnd( required array lines, required numeric startIndex ){
		for ( var index = arguments.startIndex; index <= arrayLen( arguments.lines ); index++ ) {
			if ( isSectionBoundary( arguments.lines[ index ] ) ) {
				return index;
			}
		}
		return arrayLen( arguments.lines ) + 1;
	}

	private boolean function isSectionBoundary( required string line ){
		return reFind( "^####\s", arguments.line ) || reFind( "^\[.+\]:\s*http", arguments.line );
	}

	private array function copyLines( required array lines, required numeric startIndex, required numeric endIndex ){
		var copiedLines = [];
		for ( var index = arguments.startIndex; index <= arguments.endIndex; index++ ) {
			if ( index >= 1 && index <= arrayLen( arguments.lines ) ) {
				copiedLines.append( arguments.lines[ index ] );
			}
		}
		return copiedLines;
	}

	private void function trimBlankEdges( required array lines ){
		while ( arrayLen( arguments.lines ) && !len( trim( arguments.lines[ 1 ] ) ) ) {
			arguments.lines.deleteAt( 1 );
		}
		while ( arrayLen( arguments.lines ) && !len( trim( arguments.lines[ arrayLen( arguments.lines ) ] ) ) ) {
			arguments.lines.deleteAt( arrayLen( arguments.lines ) );
		}
	}
}
