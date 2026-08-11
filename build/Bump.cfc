/**
 * Updates the project version and changelog for a release.
 *
 * Run `box run-script bump:patch`, `bump:minor`, or `bump:major` from the project root.
 * The task updates the version in box.json. It also moves the [Unreleased] notes into a dated
 * section for the new version.
 *
 * The task does not commit, tag, or publish anything. Use `:dryRun=true` to preview the file
 * changes. Use `:level=none` for a first release that already has the correct version number.
 */
component {

	/** Loads the shared settings and the two services used by this task. */
	function init(){
		variables.config           = new BuildConfig( getDirectoryFromPath( getCurrentTemplatePath() ) );
		variables.settings         = variables.config.getSettings();
		variables.versionService   = new lib.VersionService();
		variables.changelogService = new lib.ChangelogService();
		return this;
	}

	/**
	 * Calculates both file changes before writing either file.
	 *
	 * @level  How much to raise. See the list in nextVersion(), or run with an unknown level to
	 *         have them printed.
	 * @preid  The prerelease label to use, such as beta or alpha. Only used by the pre levels.
	 *         Defaults to beta when starting a prerelease.
	 * @dryRun Show what would change without writing anything.
	 * @allowPrereleaseRetarget Allow preminor to move an active prerelease to the next minor
	 *                          version. Defaults to false to prevent accidental retargeting.
	 */
	function run(
		string level = "patch",
		string preid = "",
		boolean dryRun = false,
		boolean allowPrereleaseRetarget = false
	){
		var requestedLevel = lCase( trim( arguments.level ) );
		if ( !listFindNoCase( variables.versionService.supportedLevels(), requestedLevel ) ) {
			return fail(
				"Unknown level '#arguments.level#'.",
				[
					"major, minor, patch            raise the version. On a prerelease these settle on",
					"                               the version it was leading up to.",
					"prerelease                     step a prerelease forward, beta.3 to beta.4.",
					"premajor, preminor, prepatch   start a prerelease, :preid=beta by default.",
					"none                           keep the version and just date the changelog."
				],
				"The levels you can use"
			);
		}

		var currentVersion = variables.config.version();
		var currentParts   = variables.versionService.parseVersion( currentVersion );
		if (
			requestedLevel == "preminor"
			&& len( currentParts.prerelease )
			&& !arguments.allowPrereleaseRetarget
		) {
			return fail(
				"#currentVersion# is already a prerelease, so preminor was stopped before it could target the next minor version.",
				[
					"box run-script bump:prerelease              advance the current prerelease",
					":allowPrereleaseRetarget=true               deliberately target the next minor prerelease"
				],
				"Choose the intended prerelease action"
			);
		}
		var newVersion     = currentVersion;
		var releaseDate    = dateFormat( now(), "yyyy-mm-dd" );
		var newChangelog   = "";

		try {
			if ( requestedLevel != "none" ) {
				newVersion = variables.versionService.nextVersion(
					currentVersion,
					requestedLevel,
					trim( arguments.preid )
				);
			}

			// Calculate the complete changelog first. This prevents a partial update when the
			// [Unreleased] section is missing or empty.
			newChangelog = buildChangelog( newVersion, releaseDate );
		} catch ( any exception ) {
			if ( exception.type == "BuildVersion.NotPrerelease" ) {
				return fail(
					exception.message,
					[
						"box run-script bump:beta     the next minor release as a beta",
						"box run-script bump:alpha    the same release with an alpha label",
						":level=prepatch              a prerelease of the next patch",
						":level=premajor              a prerelease of the next major"
					],
					"To start a prerelease"
				);
			}
			return error( exception.message );
		}

		if ( arguments.dryRun ) {
			print
				.line()
				.boldYellowLine( "Dry run: nothing was written." )
				.line( "Version:   #currentVersion# -> #newVersion#" )
				.line( "Changelog: notes would move into #### [#newVersion#] - #releaseDate#" )
				.line()
				.boldLine( "The new changelog would start like this:" )
				.line( left( newChangelog, 600 ) )
				.toConsole();
			return;
		}

		if ( newVersion != currentVersion ) {
			setBoxVersion( newVersion );
			print.greenLine( "box.json: #currentVersion# -> #newVersion#" ).toConsole();
		} else {
			print.greenLine( "box.json stays at #currentVersion# (level=none)." ).toConsole();
		}

		fileWrite( variables.config.repoPath( variables.settings.changelog ), newChangelog );
		print.greenLine( "#variables.settings.changelog#: notes moved into #### [#newVersion#] - #releaseDate#" ).toConsole();

		print
			.line()
			.boldMagentaLine( "Now at #newVersion#. Next steps:" )
			.line( "  1. Review:        git diff -- box.json ""#variables.settings.changelog#""" )
			.line( "  2. Stage:         git add box.json ""#variables.settings.changelog#""" )
			.line( "  3. Check staged:  git diff --staged" )
			.line( "  4. Commit:        git commit -m ""Release #newVersion#""" )
			.line( "  5. Check:         box run-script release:check" )
			.line( "  6. Release:       box run-script release" )
			.toConsole();
	}

	// PRIVATE HELPERS

	/**
	 * Stops the task, printing guidance that spans several lines.
	 *
	 * CommandBox's error() removes line breaks from its message, so anything longer than a
	 * sentence arrives as one run-together block. The guidance is printed first, where it keeps
	 * its shape, and error() is left with the single line that says what went wrong. That is
	 * also why the list appears above the error rather than below it: error() ends the task.
	 *
	 * @summary One line saying what went wrong.
	 * @detail  Lines of guidance to print first.
	 * @heading A short label for the guidance.
	 */
	private function fail( required string summary, array detail = [], string heading = "What to do" ){
		if ( arrayLen( arguments.detail ) ) {
			print.line().boldLine( arguments.heading & ":" ).toConsole();
			for ( var line in arguments.detail ) {
				print.yellowLine( "  " & line ).toConsole();
			}
			print.line().toConsole();
		}
		return error( arguments.summary );
	}

	/**
	 * Writes the new version into box.json, replacing only that one value so the rest of the
	 * file keeps its formatting.
	 *
	 * @version The new version.
	 */
	private function setBoxVersion( required string version ){
		var boxPath    = variables.config.repoPath( "box.json" );
		var packageText = fileRead( boxPath );

		// Find the first "version":"..." and replace what sits between the quotes. This splices
		// the text rather than using a replacement pattern: a pattern like "\1" placed directly
		// before a version starting with a digit reads as a different group number and eats
		// characters.
		var versionMatch = reFind( '("version"\s*:\s*")([^"]*)(")', packageText, 1, true );
		if ( !arrayLen( versionMatch.pos ) || versionMatch.pos[ 1 ] == 0 ) {
			return error( "Could not find a ""version"" entry in box.json." );
		}
		var valueStart  = versionMatch.pos[ 3 ];
		var valueLength = versionMatch.len[ 3 ];
		fileWrite(
			boxPath,
			left( packageText, valueStart - 1 )
				& arguments.version
				& mid( packageText, valueStart + valueLength, len( packageText ) )
		);
	}

	/**
	 * Reads the changelog and asks ChangelogService to build the updated text.
	 *
	 * @version The version to date the section with.
	 * @date    Today, as YYYY-MM-DD.
	 */
	private string function buildChangelog( required string version, required string date ){
		var changelogPath = variables.config.repoPath( variables.settings.changelog );
		if ( !fileExists( changelogPath ) ) {
			throw(
				type    = "BuildChangelog.MissingFile",
				message = "No #variables.settings.changelog# found in the project root. "
					& "Create one with an ""#### [Unreleased]"" section, or run: "
					& "box task run taskFile=build/Install.cfc"
			);
		}

		return variables.changelogService.moveUnreleasedNotes(
			content       = fileRead( changelogPath ),
			version       = arguments.version,
			date          = arguments.date,
			changelogName = variables.settings.changelog
		);
	}
}
