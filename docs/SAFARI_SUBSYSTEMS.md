# Safari's subsystems in a profile's process

What Safari's frameworks bring up in a profile's own process, whether a profile needs it, what it
does there now, where its data goes, and what checks it. Owner's request, 1 November, after a
profile ended on youtube.com in Safari's app-link banner tracker: "until this list exists we do not
know how many such crashes are still ahead".

**How it was made.** A census of the objects alive in a profile's own process (`heap` on the process,
a debuggable build), with Safari's window open, a page loaded through the profile's proxy and the
app-link tracker asked once (branch `claude/measure-banner`, CI 571, macOS 26.6 and 27.0.1); the
list of what that process wrote in the profile's home; Safari's path getters that answered nil
there; and what this build does to each subsystem (`SafariChrome`, `SafariPaths`,
`ProfileNetworkGuard`, `HandOffs`). About 430 classes of Safari's images had live objects; they
are grouped below by what they do. **A census shows what is up after one page, not what a person
reaches by using every menu**: the menu walk (docs/SAFARI_MENU.md) is that, and what it brings up
beyond this is not yet counted.

**Measured** means a run shows it; **not measured** means only the code or the census says so, and
the row says what would show it.

## Needed, and working in the profile

| Subsystem (Safari's classes) | Data, in the profile's home | Checked by |
|---|---|---|
| Window, tabs, toolbar, address bar (`BrowserWindowController`, `BrowserTabViewItem`, `UnifiedField…`, `UnifiedTabBar`, `ToolbarController`) | window and UI state: the profile's defaults domain (`Library/PrivacyBrowser/SafariDefaults.plist`) | self-test "Safari chrome" (65 checks), menu walk |
| Navigation and page delegates (`BrowserNavigationDelegate`, `BrowserUIDelegate`, `BrowserInputDelegate`) | — | self-test "Safari chrome" |
| Menu bar (Safari's `MainMenu.nib`) | — | menu walk (fails on change) |
| Search providers and the address bar's local completion (`SearchProvidersController`, `Safari::UnifiedFieldCompletionController`, `CompletionListCollectionViewController`) | the profile's defaults | self-test (Safari's services set as the profile needs them) |
| Favicons, touch icons, template icons (`FaviconProvider`, `WBSFaviconProviderDatabaseController`, `TemplateIconCache`) | `Library/Safari/Favicon Cache`, `Template Icons` | capture's coverage (a SKIP on runners: Safari fetched no touch icon there) |
| Link metadata of tabs (`WBSLPLinkMetadataProvider`, `WBSLPLinkMetadataSQLiteStore`) | `Library/Safari/Metadata Cache/LPLinkMetadata.db` | packet capture only |
| Top sites (`TopSitesController`) | `Library/Safari/TopSites.plist` | — |
| Per-site settings (`WBSPerSitePreferencesSQLiteStore`, zoom, pop-ups, downloads, content blockers, Lockdown Mode preference managers) | `Library/Safari/PerSitePreferences.db` | — |
| User-defined content blockers (`WBSUserDefinedContentBlockerSQLiteStore`) | `Library/Safari/UserDefinedContentBlockers.db` | — |
| Highlights (`HighlightManager`, `WBSBlockedHighlightsBannerSQLiteStore`) | `Library/Safari/BlockedBannerHighlights.db` | — |
| Tab snapshots, previews (`TabSnapshotCacheWithPersistence`, `TabPreviewController`) | the profile's caches | — |
| Reader, find, media and autoplay state, pinned and closed tabs | — | — |

## Needed, and not working in the profile

| Subsystem | What happens | Where it stands |
|---|---|---|
| Bookmarks (`BookmarksController`, `WebBookmarkGroup`, WebBookmarks) | the database opens "at (null)" (SQLite 11); no `Bookmarks.plist` is in the profile's home after a run | open (O4) |
| History (`History`, `HistoryController`, `WBSHistoryServiceStore`) | Safari's History service is an XPC service of Safari's, refused to the process: History menu empty; visits go to the profile's own encrypted history | open (H1) |
| Downloads (`DownloadsManager`) | a download does nothing and says nothing (its location view is a refused remote view) | open (O6) |
| Tab groups' collection (`WBTabGroupManager`, `WBTabCollection`) | "Failed to instantiate tab collection" at first launch | open (O4) |

## Not needed: closed

| Subsystem | Why not needed | What this build does | Checked by |
|---|---|---|---|
| Safari's AutoFill — passwords, cards, forms (`FormAutoFillController`, `AutoFillLocalAuthenticationManager`, `SFAutoFillFeatureManager`, `WBSAutoFillJavaScriptInjectionController`, `AutomaticPasswordChangeWebBrowserSessionManager`) | its store is the Mac's keychain, shared by every profile and the real Safari | form submissions kept from it, offers to save stubbed, insert actions off | self-test (form submitted, nothing reached) |
| App-link banner's tracker (`WBSAppLinkBannerTracker`) | — | `-load` and `-_saveOnInteralQueue` do nothing (17e0500): its path is nil here and its read ended the process | self-test "Safari's app-link banner tracker" (fails without the change: CI 571) |
| Tab clustering (`_setUpClusterManagerIfNeeded`) | Swift traps without Safari's services | stubbed | Safari's window opens (self-test) |
| Page text donated to Siri (`donatePageTextMetadata…`) | traps five seconds after a page | stubbed | — |
| Start page onboarding | traps on a new tab | stubbed | menu walk (⌘T) |
| Web-extension store migration (`WBSWebExtensionSQLiteStoreMigrator`) | extensions of the real Safari have no place in a profile | stubbed; Safari Extensions… disabled | menu walk |
| Tab-group sync (`WBTabGroupSyncAgentProxy` sync and observers) | its agent is refused; observers crashed a profile | stubbed (3 methods) | scale check |
| Completion list's remote view (`SPSafariPlatformSupport`) | a view of a refused service; asked again in a loop | stubbed in every profile's process (bd9628e) | self-test (iPhone view idle 0 %, control 99 %) |
| Default-browser question, Settings (⌘,), restorable state | not a profile's business | stubbed / our Settings | self-test, menu walk |
| Safari's XPC services (`com.apple.Safari*`: SafariPlatformSupport helper, SearchHelper, CredentialExtractionHelper, extension helpers, configuration subscriber) | they reach the real Safari's data, the keychain and the network outside the proxy | refused by the kernel | XPC service watch (self-test) |
| Add to Dock, browsing-data import/export, Shared with You | outside the profile (owner's decisions) | removed from the menu | menu walk |

## Not needed, up in the process, not measured — to measure first

These are the rows the census raised. Each is a way for a profile's browsing to reach the Mac's
own stores or another app, outside the profile; none has been shown to happen or not to.

| Subsystem (census) | The question | What would show it |
|---|---|---|
| **Biome** (`WBSBiomeDonationManager`, `_WBSBiomeStream`; BiomeStreams, BiomeFoundation, BiomeStorage loaded) | does Safari donate a profile's visits to the Mac's Biome store (Siri suggestions, Screen Time), outside the profile? | count the donation calls in a profile's process; look for the run's pages in the account's Biome streams |
| **Spotlight** (`CSSearchableIndex`, `WBSSpotlightReindexingBackgroundSystemTaskManager`, `WBSSpotlightDonationEntityCorrelator`, `SpotlightBookmarksWriter`) | does a profile's history or bookmarks go into the Mac's Spotlight index? | count `-[CSSearchableIndex indexSearchableItems:…]` calls; `mdfind` for the run's page titles after a run |
| **App links** (`WBSAppLink`, `AppLinkBannerController`, `ExternalURLNavigationHandler`) | on a Mac with an app or web app for a site, does the banner's Open — or a link Safari decides to open in the app — hand the page's address to that app? | an app link a runner can have (a crafted web app); `HandOffs`' refusals and the app's own launch |
| Apple Intelligence and page context (`WBSPageContextManager`, `WBSBrowsingAssistantController`, `IntelligenceCollectionCoordinator`, `IntelligenceSupportAgentXPCConnection`) | is a page's content sent to the system's intelligence service? | count the calls; the XPC service watch |
| Translation (`WBSTranslation…`, `_LTTranslator`) | on-device or Apple's servers, and through which proxy | translate a page in a profile with the capture on |
| Remote configuration and quirks (`WBSConfigurationDownloader`, `WBSRemotelyUpdatableDataController`, user-agent, AutoFill and autoplay quirks, offline search models, Trial) | fetched by the process (through its proxy) or by a daemon (as this Mac)? | the packet capture over a longer run; the XPC service watch for triald |
| Analytics (`WBSAnalyticsLogger`, search and address-bar impression recorders) | sent through the Mac's analytics, with what of the profile's browsing? | count the calls; what reaches analyticsd |
| Apple account (`WBSPrimaryAppleAccountObserver`), iCloud bookmarks migration, settings sync (`SafariSettingsSyncEngine`), shared tab groups' presence (`WBParticipantPresenceCoordinator`) | do they reach iCloud with the Mac's account from a profile? | the XPC service watch; the capture |
| Private Relay (`WBSPrivacyProxyAvailabilityManager`) | does iCloud Private Relay apply to a profile's traffic as well as its own proxy? | a Mac with iCloud+; not a runner |
| Quick Note (`WBSSystemNoteTakingController`), sign-in for other apps (`ASWebAuthenticationSession…`) | handing a page to Notes or another app | `HandOffs`' refusals |

## Paths Safari has none for in a profile's process

The kind of fault that ended the profiles on youtube.com: a getter of Safari's that answers nil in a
profile's process, read later into a file URL. Measured (CI 566, 571): `-[WBSBannerTracker
_filePath]`, `-[NSFileManager safari_containerSettingsDirectory]` (extensions in a profile),
`-[NSFileManager safari_autoFillQuirksDownloadDirectoryURL]`, `-[WBSSQLiteStore databaseURL]` (the
sandbox-extension store), `-[WebBookmarkGroup davHomeURL]`, and the bookmarks database "(null)".
Only the tracker's is known to reach a throw; the others are what the next measurement walks for —
every file URL asked for with no path, over the whole menu walk and pages, with who asked.
