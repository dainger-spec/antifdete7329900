# Framework window probe

macOS 26.6.2 (25G83), arm64, SIP: System Integrity Protection status: disabled.
built with SDK 26.5, Xcode 26.6 Build version 17F113
app: build/unsandboxed/PrivacyBrowser.app

| step | outcome | seconds | why |
|---|---|---|---|
| image | exited 0 | 0.8 |  |
| classes | exited 0 | 0.1 |  |
| selectors | exited 0 | 0.6 |  |
| appcontroller | exited 0 | 0.1 |  |
| windowcontroller | exited 0 | 0.1 |  |
| documentcontroller | exited 0 | 0.0 |  |
| documentcontroller-create | exited 0 | 0.5 |  |
| webconfig | exited 0 | 0.3 |  |
| shared | exited 0 | 0.1 |  |
| create-direct | killed by SIGTRAP | 1.1 | SIGNAL 5 / Trace/BPT trap: 5 / EXC_BREAKPOINT SIGTRAP |
| create | killed by SIGTRAP | 0.9 | SIGNAL 5 / Trace/BPT trap: 5 / EXC_BREAKPOINT SIGTRAP |
| create-bootstrap | killed by SIGTRAP | 0.7 | raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value |
| window | killed by SIGTRAP | 1.6 | SIGNAL 5 / Trace/BPT trap: 5 / EXC_BREAKPOINT SIGTRAP |
| popupfield | exited 0 | 0.2 |  |
| popup | killed by SIGTRAP | 0.7 | SIGNAL 5 / Trace/BPT trap: 5 / EXC_BREAKPOINT SIGTRAP |
| popup-nofield | killed by SIGTRAP | 0.8 | SIGNAL 5 / Trace/BPT trap: 5 / EXC_BREAKPOINT SIGTRAP |
| popup-mode | killed by SIGTRAP | 0.8 | SIGNAL 5 / Trace/BPT trap: 5 / EXC_BREAKPOINT SIGTRAP |
| popup-hidden | exited 0 | 5.4 | raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x103c60960; no window |
| popup:crash-off | killed by SIGTRAP | 0.7 | SIGNAL 5 / Trace/BPT trap: 5 / EXC_BREAKPOINT SIGTRAP |
| window:chrome | killed by SIGTRAP | 0.7 | SIGNAL 5 / Trace/BPT trap: 5 / EXC_BREAKPOINT SIGTRAP |

## image — exited 0

```
PROBE step image
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE candidate /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari: on disk false
PROBE candidate /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari: on disk false
PROBE candidate /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari: on disk false
PROBE candidate /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari: on disk false
PROBE candidate /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari: on disk false
PROBE candidate /System/Library/PrivateFrameworks/Safari.framework/Safari: on disk false
PROBE dlopen succeeded: true
PROBE   failed /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (on disk false): dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file)
PROBE   failed /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (on disk false): dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file)
PROBE   failed /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari (on disk false): dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file)
PROBE   failed /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari (on disk false): dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file)
PROBE opened path: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE dyld image name: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE loaded images of interest (13):
PROBE   /System/Library/Frameworks/WebKit.framework/Versions/A/WebKit
PROBE   /System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebKitLegacy.framework/Versions/A/WebKitLegacy
PROBE   /System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/Frameworks/libwebrtc.dylib
PROBE   /System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/WebCore
PROBE   /System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/Frameworks/libANGLE-shared.dylib
PROBE   /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   /System/Library/PrivateFrameworks/SafariFoundation.framework/Versions/A/SafariFoundation
PROBE   /System/Library/PrivateFrameworks/SafariSwift.framework/Versions/A/SafariSwift
PROBE   /System/Library/PrivateFrameworks/SafariSafeBrowsing.framework/Versions/A/SafariSafeBrowsing
PROBE   /System/Library/Frameworks/SafariServices.framework/Versions/A/SafariServices
PROBE   /System/Library/PrivateFrameworks/SafariShared.framework/Versions/A/SafariShared
PROBE   /System/Library/PrivateFrameworks/SafariSharedUI.framework/Versions/A/SafariSharedUI
PROBE   /System/Library/PrivateFrameworks/SafariCore.framework/Versions/A/SafariCore
PROBE what the framework bundle holds on disk:
PROBE   /System/Library/PrivateFrameworks/Safari.framework: 3 entries; PlugIns, Resources, Versions
PROBE   /System/Library/PrivateFrameworks/Safari.framework/Versions/A: 3 entries; PlugIns, Resources, _CodeSignature
PROBE   /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Resources: 69 entries, 42 .lproj (de.lproj, he.lproj, en_AU.lproj, ar.lproj); ContactsAutoFillChoicesMenuItemView.nib, ExtensionCheckmark.svg, ar.lproj, de.lproj, el.lproj, en.lproj, en_AU.lproj, he.lproj, ja.lproj, uk.lproj
PROBE   /System/Library/PrivateFrameworks/Safari.framework/Resources: 69 entries, 42 .lproj (de.lproj, he.lproj, en_AU.lproj, ar.lproj); ContactsAutoFillChoicesMenuItemView.nib, ExtensionCheckmark.svg, ar.lproj, de.lproj, el.lproj, en.lproj, en_AU.lproj, he.lproj, ja.lproj, uk.lproj
PROBE   Bundle(path:) -> loaded=false, identifier=com.apple.Safari.framework
PROBE step image finished
2026-10-29 08:19:31.478 PrivacyBrowser[3512:14479] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:31.479 PrivacyBrowser[3512:14479] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:31.479 PrivacyBrowser[3512:14479] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:31.479 PrivacyBrowser[3512:14479] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:32.246 PrivacyBrowser[3512:14479] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## classes — exited 0

```
PROBE step classes
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE classes in the image: 1078
PROBE wrote framework-classes.txt (30915 bytes)
PROBE *AppController*: 3 -> AppController, AppControllerTouchBarProvider, WebAppController
PROBE *BrowserWindowController*: 1 -> BrowserWindowController
PROBE *BrowserViewController*: 3 -> BrowserViewController, BrowserViewControllerNavigationManager, BrowserViewControllerWindowConfiguration
PROBE *WindowController*: 6 -> BrowserWindowController, CompletionListWindowController, FullscreenUnifiedFieldWindowController, OverlayStatusWindowController, TabPreviewWindowController, WindowController
PROBE *Profile*: 11 -> AcceptSharedTabGroupInProfileAlertController, CreateProfilePreferencesViewController, ExtensionsProfilesPreferencesViewController, GeneralProfilesPreferencesViewController, ProfileIconButton, ProfileIconPickerCollectionViewController, ProfileIconPickerCollectionViewItem, ProfileIconPickerViewController, ProfileTitleTextField, ProfilesPreferences, ProfilesPreferencesTableCellView
PROBE *WebView*: 2 -> VisualTabPickerWebViewThumbnailView, WebViewController
PROBE *TabContent*: 2 -> TabContentView, TabContentViewController
PROBE *BrowserWindow*: 8 -> AutomationBrowserWindow, BrowserWindow, BrowserWindowContentSplitViewController, BrowserWindowContentViewController, BrowserWindowController, BrowserWindowPersistentState, BrowserWindowTabView, BrowserWindowTabViewController
PROBE step classes finished
2026-10-29 08:19:32.285 PrivacyBrowser[3513:14494] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:32.285 PrivacyBrowser[3513:14494] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:32.285 PrivacyBrowser[3513:14494] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:32.285 PrivacyBrowser[3513:14494] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:32.294 PrivacyBrowser[3513:14494] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## selectors — exited 0

```
PROBE step selectors
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE _newWindowWithFrontmostProfile:: AppController
PROBE _createNewWindowWithFrontmostProfile:: AppController
PROBE newWindowWithFrontmostProfile:: nil — no class in the image declares it
PROBE showWindow:: BrowserWindowController
PROBE _didCompleteContentSetup: BrowserWindowController
PROBE selectors matching ["newwindow"]: 22 classes
PROBE   AppController: _createNewWindowWithFrontmostProfile:, _eventModifierFlagsForNewWindow, _newWindowFromDock:, _newWindowWithDefaultProfile:, _newWindowWithFrontmostProfile:, _prepareBrowserContentViewControllerForNewUserActivityUsingPrivateBrowsingForNewWindow:, createNewWindowWithRequestIdentifier:isPrivate:, moveCurrentTabToNewWindow:
PROBE   AppControllerTouchBarProvider: _openNewWindow:, newWindowButton
PROBE   MacSafariBookmarkDBAccess: _fallbackNewWindowBehaviorBookmarkFolderProvider
PROBE   BookmarksController: bookmarkForNewWindowTabsPreferenceForProfileIdentifier:
PROBE   BookmarkSource: goToContentItemInNewWindow:
PROBE   BookmarksViewController: goToContentItemInNewWindow:
PROBE   BrowserApplication: createNewWindowFromTouchBarProvider:
PROBE   BrowserDocumentController: _newTabInNewWindowWithBrowsingMode:sender:
PROBE   BrowserUIDelegate: _appendNewWindowAndTabMenuItemsToMenu:newWindowTitle:newWindowAction:newTabTitle:newTabAction:alternativeNewWindowTitle:alternativeNewWindowAction:enableNewWindowMenuItems:contextMenuInfo:, _appendNewWindowAndTabMenuItemsToMenu:prefixString:newNonPrivateWindowAction:newPrivateWindowAction:newAutomationWindowAction:newTabAction:contextMenuInfo:, _appendOpenFrameInNewWindowAndTabMenuItemsToMenu:openFrameInNewWindowExistingMenuItem:contextMenuInfo:, _appendOpenImageInNewWindowAndTabMenuItemsToMenu:openImageInNewWindowExistingMenuItem:contextMenuInfo:, _appendOpenLinkInNewWindowAndTabMenuItemsToMenu:openLinkInNewWindowExistingMenuItem:contextMenuInfo:, _appendOpenMediaInNewWindowAndTabMenuItemsToMenu:openMediaInNewWindowExistingMenuItem:elementType:contextMenuInfo:, _appendOpenQRCodePayloadURLInNewWindowAndTabMenuItemsToMenu:contextMenuInfo:, _openFrameInNewWindowFromContextMenuInfo:windowPolicy:
PROBE   BrowserViewController: browserWKViewDidMoveToNewWindow
PROBE   BrowserWindowController: _moveTabGroupTabsToNewWindow:, _moveTabToNewWindow:, _moveTabsToNewWindow:, _newWindowShouldBeUnbuffered, _notifyPageAboutBarsStatesAfterMovingToNewWindow:, _openBookmarksInTabsForNewWindow, _replaceEmptyTabInNewWindowWithTabs:, _shouldUseOpenBookmarksInTabsNewWindowBehavior
PROBE   GeneralPreferences: _updateNewWindowBehaviorViews, _updateNewWindowTabsMenuItem, takeNewWindowBehaviorFrom:
PROBE selectors matching ["createnewwindow"]: 3 classes
PROBE   AppController: _createNewWindowWithFrontmostProfile:, createNewWindowWithRequestIdentifier:isPrivate:
PROBE   BrowserApplication: createNewWindowFromTouchBarProvider:
PROBE   SafariWebExtensionsController: _findBrowserTabViewItemOrCreateNewWindowForNewTabWithBrowsingMode:URL:shouldMakeNewTabActive:shouldMakeKeyNewWindow:
PROBE selectors matching ["frontmostprofile"]: 2 classes
PROBE   AppController: _createNewWindowWithFrontmostProfile:, _newWindowWithFrontmostProfile:
PROBE   BrowserDocumentController: frontmostProfileIdentifier, setFrontmostProfileIdentifier:
PROBE selectors matching ["websitedatastore"]: 4 classes
PROBE   AppController: _setWKWebsiteDataStoreDelegate, websiteDataStore:domain:didExceedMemoryFootprintThreshold:withPageCount:processLifetime:inForeground:wasPrivateRelayed:canSuspend:, websiteDataStore:domain:didOpenDomainViaWindowOpen:withProperty:directly:, websiteDataStore:navigateToNotificationActionURL:, websiteDataStore:openWindow:fromServiceWorkerOrigin:completionHandler:, websiteDataStore:workerOrigin:updatedAppBadge:
PROBE   BrowserUIDelegate: websiteDataStore:getDisplayedNotificationsForWorkerOrigin:completionHandler:
PROBE   SearchableWKView: websiteDataStore
PROBE   WebViewController: websiteDataStore
PROBE selectors matching ["profile", "window"]: 8 classes
PROBE   AppController: _addNewProfileWindowOptionsWithProfiles:toApplicationDockMenuOrSubmenu:, _createNewWindowWithFrontmostProfile:, _newProfileWindowFromDock:, _newWindowWithDefaultProfile:, _newWindowWithFrontmostProfile:, _updateNewProfileWindowMenuItems, _validateNewProfileWindowMenuItem:, newProfileWindowFromMenu:
PROBE   BookmarksController: bookmarkForNewWindowTabsPreferenceForProfileIdentifier:
PROBE   BrowserDocument: initWithBrowsingMode:configuration:profileIdentifier:isPopupWindow:restoringFromLastSession:, initWithContentsOfRequest:browsingMode:profileIdentifier:automationSessionIdentifier:isPopupWindow:, profileDisplayTitleInWindow, setProfileDisplayTitleInWindow:
PROBE   BrowserDocumentController: _frontmostBrowserDocumentIfAvailableInProfileWithIdentifier:usingWindowPolicy:browsingMode:forExternalLink:, _frontmostBrowserDocumentIfAvailableUsingWindowPolicy:profileIdentififier:, _goToEachRequest:tabLabels:windowPolicy:tabPlacementHint:forSearch:inNewProcess:profileIdentifier:, _goToRequest:tabLabel:windowPolicy:tabPlacementHint:forSearch:inNewProcess:profileIdentifier:, _openDocumentWithContentsOfRequest:behind:display:browsingMode:isPopupWindow:inProfileIdentifier:, createHiddenBrowserDocumentForWebExtensionsWithBrowsingMode:profileIdentifier:shouldLoadUserStartPage:isPopupWindow:, createHiddenEmptyBrowserDocumentWithBrowsingMode:profileIdentifier:configuration:suppressSidebar:isPopupWindow:, createHiddenEmptyBrowserDocumentWithBrowsingMode:profileIdentifier:isPopupWindow:
PROBE   BrowserSessionPersistentState: initWithPinnedTabsStates:privatePinnedTabsStates:pinnedTabsStatesByProfileIdentifier:windowStates:
PROBE   BrowserWindowController: closeProfileWindow:, isInSameProfileAsBrowserWindowController:, profileWindow:selectProfile:, profileWindow:selectTabGroup:, willCloseProfileWindow
PROBE   ClosedTabOrWindowStateManager: _loadRecentlyClosedTabsOrWindowsFromDiskForProfilesWithIdentifiers:
PROBE   PinnedTabsManager: _attachAnyDetachedPinnedTabsToExistingWindowInProfileWithIdentifier:, _firstWindowToAttachOrphanedPinnedTabsToInProfileWithIdentifier:
PROBE wrote framework-selectors.txt (7102 bytes)
PROBE step selectors finished
2026-10-29 08:19:32.349 PrivacyBrowser[3514:14498] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:32.349 PrivacyBrowser[3514:14498] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:32.349 PrivacyBrowser[3514:14498] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:32.349 PrivacyBrowser[3514:14498] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:32.358 PrivacyBrowser[3514:14498] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## appcontroller — exited 0

```
PROBE step appcontroller
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE classes to dump: AppController
PROBE AppController: AppController <- NSObject
PROBE   734 instance methods, 9 class methods, 227 ivars, 147 properties
PROBE   *init*: _initializeInspectorProcessContextForProfileIdentifier:, _initializeNSUserDefaults, _initializeProcessContextForProfileIdentifier:, _initializeProcessContextWithoutJITForProfileIdentifier:, _openURL:forcingHTMLMIMEType:bundleIdentifierOfApplicationThatInitiatedNavigation:, _setInjectedBundleInitializationMessagesData:forKey:, init, initializationMessages, initializeShareMenuItemInFileMenu:
PROBE   *window*: _OKToCloseBrowserWindowsForExplicitCloseAllCommand:, _addNewProfileWindowOptionsWithProfiles:toApplicationDockMenuOrSubmenu:, _browserStateFromCurrentSessionIgnoringPrivateWindows:encryptionProvider:, _collectWindowsAndTabsDataTimerFired:, _consolidateTabsAndWindowsNow, _copyUnnamedOrPrivateTabGroupsFromWindowController:toWindowState:, _createBundleForDownloadWithSuggestedFilename:downloadLocationRequestType:inBrowserWindowController:completionHandler:, _createNewWindowWithFrontmostProfile:, _didFinishRestoringWindows, _eventModifierFlagsForNewWindow, _hasEverShownWindow, _newPrivateWindowFromDock:, _newProfileWindowFromDock:, _newWindowFromDock:
PROBE   *profile*: _addCreateOrManageProfilesMenuItem, _addNewProfileWindowOptionsWithProfiles:toApplicationDockMenuOrSubmenu:, _createExtensionControllersIfNeededForProfileServerID:, _createNewWindowWithFrontmostProfile:, _createOrManageProfilesMenuItemTitle, _historiesForProfiles, _initializeInspectorProcessContextForProfileIdentifier:, _initializeProcessContextForProfileIdentifier:, _initializeProcessContextWithoutJITForProfileIdentifier:, _inspectorProcessPoolForProfileIdentifier:createIfNeeded:, _loadExtensionsInProfile:, _loadTestExtensionsInProfile:, _newProfileWindowFromDock:, _newWindowWithDefaultProfile:
PROBE   *webview*: downloadsManager:browserWindowControllerForWebView:getDownloadStartOriginInWindow:, downloadsManager:shouldAllowDownload:onWebView:fromSecurityOrigin:originatingURL:completionHandler:, downloadsManager:willStartDownloadAtURL:downloadProgressEntry:forWebView:, notifyAddedLinkPreviewMetadata:toUserActivity:webView:, quickWebsiteSearchJavaScriptInjectionController:receivedDetectedSearchURLString:fromWebView:inFrame:, quickWebsiteSearchJavaScriptInjectionController:receivedOpenSearchSchemaURL:fromWebView:
PROBE   *datastore*: _processPushMessages:inDataStore:completionHandler:, _setWKWebsiteDataStoreDelegate, prewarmAndRemoveOrphanedProfileDataStores, websiteDataStore:domain:didExceedMemoryFootprintThreshold:withPageCount:processLifetime:inForeground:wasPrivateRelayed:canSuspend:, websiteDataStore:domain:didOpenDomainViaWindowOpen:withProperty:directly:, websiteDataStore:navigateToNotificationActionURL:, websiteDataStore:openWindow:fromServiceWorkerOrigin:completionHandler:, websiteDataStore:workerOrigin:updatedAppBadge:
PROBE   *configuration*: _defaultProcessConfiguration, _focusConfigurationChanged, _tabCollectionConfiguration, toggleJavaScriptConfigurationEnabled:, validate_toggleJavaScriptConfigurationEnabled:
PROBE   *shared*: _presentSharedTabGroupErrorWithMessage:informativeText:, _presentSharedTabGroupsPendingAcceptanceError, _presentSharedTabGroupsUnsupportedError, didFetchRecentlyAcceptedSharedTabGroupWithUUID:acceptedShareDate:, sharedAppController
PROBE   *new*: _addNewProfileWindowOptionsWithProfiles:toApplicationDockMenuOrSubmenu:, _clearInvalidCertificateBypassesOlderThanOneWeek, _createNewWindowWithFrontmostProfile:, _eventModifierFlagsForNewWindow, _newPrivateWindowFromDock:, _newProfileWindowFromDock:, _newWindowFromDock:, _newWindowWithDefaultProfile:, _newWindowWithFrontmostProfile:, _prepareBrowserContentViewControllerForNewUserActivity, _prepareBrowserContentViewControllerForNewUserActivityUsingPrivateBrowsingForNewWindow:, _prepareBrowserContentViewControllerForNewUserActivityWithDelay:, _updateNewProfileWindowMenuItems, _validateNewProfileWindowMenuItem:
PROBE   *tab*: _allTabsWithExtensionContentLoadedForExtensionHost:, _collectWindowsAndTabsDataTimerFired:, _computeCurrentSafariTabState, _computeLastSessionTabCount, _consolidateTabsAndWindowsNow, _copyTabsFromTabGroup:toTabGroupWithUUID:isPrivate:, _copyUnnamedOrPrivateTabGroupsFromWindowController:toWindowState:, _duplicateLastSessionStateAndSaveToDatabase, _ensureTabSnapshotVendor, _eventIsOldSelectNextPreviousTabKeyEquivalent:direction:, _eventIsSelectNextTabKeyEquivalent:, _eventIsSelectPreviousTabKeyEquivalent:, _eventIsTabGroupNavigationKeyEquivalent:direction:, _eventIsTabNavigation:direction:nextDirectionKey:previousDirectionKey:
PROBE   ivars naming a store or a profile: _didRestoreStateDuringLaunch  B | _createOrManageProfilesMenuItem  @"NSMenuItem" | _newDefaultProfileWindowMenuItem  @"NSMenuItem" | _newProfileWindowMenuItem  @"NSMenuItem" | _lastMenuUpdateProfileIdentifiers  @"NSArray" | _focusProfileIdentifier  @"NSString" | _profileServerIDToAppExtensionsControllers  @"NSMutableDictionary" | _profileServerIDToWebExtensionsControllers  @"NSMutableDictionary" | _profileServerIDToContentBlockerManagers  @"NSMutableDictionary" | _profileServerIDToUserContentController  @"NSMutableDictionary" | _acceptSharedTabGroupInProfileAlert  @"AcceptSharedTabGroupInProfileAlertController" | _profileIdentifiersToRecentWebSearchesController  @"NSMutableDictionary" | _profileIdentifiersToSuggestionsManagers  @"NSMutableDictionary" | _triedToRestoreWithTabPersistentState  B | _webAppVisitedLinkStore  @"_WKVisitedLinkStore" | _profilePreferenceManager  @"WBSProfilePreferenceManager"
PROBE wrote framework-AppController.txt (57346 bytes)
PROBE step appcontroller finished
2026-10-29 08:19:32.951 PrivacyBrowser[3516:14507] SafariLoader: classNames -> nil (framework image not in the loaded image list)
2026-10-29 08:19:32.952 PrivacyBrowser[3516:14507] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:32.952 PrivacyBrowser[3516:14507] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:32.952 PrivacyBrowser[3516:14507] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:32.952 PrivacyBrowser[3516:14507] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:32.960 PrivacyBrowser[3516:14507] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## windowcontroller — exited 0

```
PROBE step windowcontroller
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE classes to dump: BrowserWindowController
PROBE BrowserWindowController: BrowserWindowController <- WindowController <- NSWindowController <- NSResponder <- NSObject
PROBE   1455 instance methods, 21 class methods, 192 ivars, 169 properties
PROBE   *init*: _canInitiateTabGroupShare, _canInitiateTabGroupShareFromShareButton, didStartBrowserInitiatedLoadInBrowserViewController:, init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
PROBE   *window*: _backgroundLoadConfigurationForNonSpeculativeLoadInCurrentWindow, _backgroundLoadConfigurationForSpeculativeLoadInCurrentWindow, _canCloseTabWithoutClosingWindow:includingLastUnpinnedTab:, _canConsolidateTabGroupInWindowMerge:, _closeTabsAndMarkAsReusableWhileClosingWindow:, _closeWindowAfterChecks, _closeWindowIfNoUnpinnedTabsLeft, _closeWindowIfPossible, _destinationWindowForDetachedTabBarViewItems:withActiveTabIndex:, _detachedWindowImageForDraggedTabBarViewItem:, _didFinishTransitionAnimationForWindow:, _didUpdateTabViewItemsInBrowserWindowTabViewController, _displayCloseWindowConfirmSheetForLocalTabGroupIfNecessary, _displayCloseWindowConfirmSheetForPIPIfNecessary
PROBE   *profile*: _namedTabGroupsForActiveProfile, _profileIdentifierForTab:, canSwitchToAnotherProfile, closeProfileWindow:, hasMultipleProfiles, isInDefaultProfile, isInSameProfileAsBrowserWindowController:, profile, profileIdentifier, profileWindow:selectProfile:, profileWindow:selectTabGroup:, shouldShowProfileTitle, startPageShouldShowProfileTitle, tabGroupManager:didUpdateProfileWithIdentifier:difference:
PROBE   *webview*: _updateTitlebarColorFromWebView:, _updateTitlebarColorFromWebView:forceUpdate:, _updateWebAppTitlebarColorFromWebView:forceUpdate:, currentWebViewSize
PROBE   *configuration*: _backgroundLoadConfigurationForNonSpeculativeLoadInCurrentWindow, _backgroundLoadConfigurationForSpeculativeLoadInCurrentWindow, _toggleLocationBar:suppressToolbarConfigurationAutosave:, _toggleLocationBarWithoutSavingConfiguration, didClearBlockedWindowConfigurationCaches, makeBrowserViewControllerForBackgroundLoadController:configuration:urls:, makeBrowserViewControllerInTabAtIndex:configuration:andSelect:, makeBrowserViewControllerInTabOfType:configuration:andSelect:
PROBE   *shared*: _presentAttributedSharedTabNoticeWithMessage:forParticipantWithRecordID:inSharedTabGroupWithUUID:, _switchToRecentlyJoinedSharedTabGroupIfNeeded, _titleForSharedWithYouMenuItemBasedOnViewVisibility, didAddTabWithUUID:title:inSharedTabGroupWithUUID:byParticipantWithRecordID:, didChangeBackgroundImageInSharedTabGroupWithUUID:byParticipantWithRecordID:, didChangeScopedFavoritesInSharedTabGroupWithUUID:byParticipantWithRecordID:, didNavigateInTabWithUUID:title:inSharedTabGroupWithUUID:byParticipantWithRecordID:, didRemoveTabWithUUID:title:inSharedTabGroupWithUUID:byParticipantWithRecordID:, participants:didJoinSharedTabGroupWithUUID:, participants:didLeaveSharedTabGroupWithUUID:, switchToRecentlyAcceptedSharedTabGroupWithUUID:acceptedShareDate:, toggleSharedWithYou:
PROBE   *new*: _adjustedBehaviorForNewBrowserViewBehavior:, _applyNewBrowserViewBehavior:toBrowserViewController:usingReferenceBrowserViewController:, _createBrowserViewControllerAsynchronouslyInNewTabOfType:respectingNewTabBehavior:tabCreationOptions:completionHandler:, _createBrowserViewControllerInNewTabOfType:respectingNewTabBehavior:andSelect:, _didCreateBrowserViewController:formerlySelectedBrowserViewController:respectingNewTabBehavior:selectingOnCreation:, _didSelectNewTab:withLastSelectedTab:, _isTabEquivalentToNewlyCreatedTabRespectingNewTabBehavior:, _moveTabGroupTabsToNewWindow:, _moveTabToNewWindow:, _moveTabsToNewWindow:, _newTabTypeRespectingVisualTabPickerVisibility:, _newWindowShouldBeUnbuffered, _notifyPageAboutBarsStatesAfterMovingToNewWindow:, _openBookmarksInTabsForNewWindow
PROBE   *tab*: _acceptTabDrop:index:, _addPlaceholderContentToTab:, _allowsPinnedTabsInTabGroup:, _allowsScrollingPinnedTabs, _alwaysShowTabBar, _applyTabSelectionStateUpdateForTab:previouslySelectedTab:selectedTabViewItems:completionHandler:, _audioMenuTabMenuItemClicked:, _beginUniqueBackgroundLoadWithURLs:tabLabel:isSpeculative:identifier:httpReferrer:canAttemptUpgradingRequestURLToHTTPS:, _bookmarkForBrowserTabViewItem:, _browserTabPersistentStateForTab:, _browserTabViewItemForUnifiedTabBarItem:, _browserTabViewItemWithBackgroundNavigationBackgroundLoad:, _browserTabViewItemsForUnifiedTabBarItems:, _browserTabsDidChange
PROBE   ivars naming a store or a profile: _tabIndexToSelectAfterPinnedTabsAreRestored  Q | _profileWindow  @"WBProfileWindow"
PROBE wrote framework-BrowserWindowController.txt (88223 bytes)
PROBE step windowcontroller finished
2026-10-29 08:19:33.025 PrivacyBrowser[3517:14511] SafariLoader: classNames -> nil (framework image not in the loaded image list)
2026-10-29 08:19:33.025 PrivacyBrowser[3517:14511] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:33.025 PrivacyBrowser[3517:14511] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:33.025 PrivacyBrowser[3517:14511] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:33.025 PrivacyBrowser[3517:14511] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:33.035 PrivacyBrowser[3517:14511] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## documentcontroller — exited 0

```
PROBE step documentcontroller
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE classes to dump: BrowserDocumentController, BrowserDocument
PROBE BrowserDocumentController: BrowserDocumentController <- NSDocumentController <- NSObject
PROBE   103 instance methods, 1 class methods, 5 ivars, 4 properties
PROBE   *init*: _commonInit, _createBrowserDocumentWithBrowsingMode:profileIdentifier:configuration:initialSize:options:, _createBrowserDocumentWithBrowsingMode:profileIdentifier:initialSize:options:, createHiddenEmptyBrowserDocumentWithBrowsingMode:profileIdentifier:jitEnabled:isPopupWindow:restoringFromLastSession:initialSize:, goToURLFromExternalApplication:forcingHTMLMIMEType:openInNewPrivateWindowIfNecessary:bundleIdentifierOfApplicationThatInitiatedNavigation:, init, initWithCoder:
PROBE   *window*: _browserDocumentIsAvailable:usingWindowPolicy:, _closeModalWindowIfBlockingInteractionOnWindowController:, _frontmostBrowserDocumentIfAvailableInProfileWithIdentifier:usingWindowPolicy:browsingMode:forExternalLink:, _frontmostBrowserDocumentIfAvailableUsingWindowPolicy:, _frontmostBrowserDocumentIfAvailableUsingWindowPolicy:profileIdentififier:, _frontmostBrowserDocumentWithoutTabGroupSelectedIfAvailableUsingWindowPolicy:browsingMode:, _goToEachRequest:tabLabels:windowPolicy:tabPlacementHint:forSearch:inNewProcess:profileIdentifier:, _goToRequest:tabLabel:windowPolicy:tabPlacementHint:forSearch:inNewProcess:profileIdentifier:, _isNewTabDefaultForWindowUserTabbingPreference, _newTabInNewWindowWithBrowsingMode:sender:, _openDocumentWithContentsOfRequest:behind:display:browsingMode:isPopupWindow:, _openDocumentWithContentsOfRequest:behind:display:browsingMode:isPopupWindow:inProfileIdentifier:, _restoreWebAppDocumentFromWindowState:reusingDocument:forTabGroup:mainWindow:selectedWindowMapping:, _setUpNewTabOrWindowMenuItem:addOptionFlagModifier:
PROBE   *profile*: _createBrowserDocumentWithBrowsingMode:profileIdentifier:configuration:initialSize:options:, _createBrowserDocumentWithBrowsingMode:profileIdentifier:initialSize:options:, _frontmostBrowserDocumentIfAvailableInProfileWithIdentifier:usingWindowPolicy:browsingMode:forExternalLink:, _frontmostBrowserDocumentIfAvailableUsingWindowPolicy:profileIdentififier:, _goToEachRequest:tabLabels:windowPolicy:tabPlacementHint:forSearch:inNewProcess:profileIdentifier:, _goToRequest:tabLabel:windowPolicy:tabPlacementHint:forSearch:inNewProcess:profileIdentifier:, _openDocumentWithContentsOfRequest:behind:display:browsingMode:isPopupWindow:inProfileIdentifier:, _profileIdentifierForURLRequest:, createHiddenBrowserDocumentForWebExtensionsWithBrowsingMode:profileIdentifier:shouldLoadUserStartPage:isPopupWindow:, createHiddenEmptyBrowserDocumentWithBrowsingMode:profileIdentifier:configuration:suppressSidebar:isPopupWindow:, createHiddenEmptyBrowserDocumentWithBrowsingMode:profileIdentifier:isPopupWindow:, createHiddenEmptyBrowserDocumentWithBrowsingMode:profileIdentifier:jitEnabled:isPopupWindow:restoringFromLastSession:initialSize:, createHiddenEmptyBrowserDocumentWithProfileIdentifier:, createHiddenEmptyBrowserDocumentWithoutLoadingWindowWithBrowsingMode:profileIdentifier:
PROBE   *configuration*: _createBrowserDocumentWithBrowsingMode:profileIdentifier:configuration:initialSize:options:, createHiddenEmptyBrowserDocumentWithBrowsingMode:profileIdentifier:configuration:suppressSidebar:isPopupWindow:
PROBE   *shared*: sharedDocumentController
PROBE   *new*: _createNewTabAsynchronouslyInCurrentContext:sender:completionHandler:, _goToEachRequest:tabLabels:windowPolicy:tabPlacementHint:forSearch:inNewProcess:profileIdentifier:, _goToRequest:tabLabel:windowPolicy:tabPlacementHint:forSearch:inNewProcess:profileIdentifier:, _isNewTabDefaultForWindowUserTabbingPreference, _newTabInCurrentContext:browsingMode:sender:, _newTabInNewWindowWithBrowsingMode:sender:, _setUpNewTabOrWindowMenuItem:addOptionFlagModifier:, browsingModeForNewDocument, canCreateNewTab, createNewTabForAppIntentsInPrivateBrowsing:, goToRequest:tabLabel:windowPolicy:tabPlacementHint:inNewProcess:, goToURLFromExternalApplication:forcingHTMLMIMEType:openInNewPrivateWindowIfNecessary:bundleIdentifierOfApplicationThatInitiatedNavigation:, newTab:, newTabAtEndFromFileMenu:
PROBE   *tab*: _createNewTabAsynchronouslyInCurrentContext:sender:completionHandler:, _frontmostBrowserDocumentWithoutTabGroupSelectedIfAvailableUsingWindowPolicy:browsingMode:, _goToEachRequest:tabLabels:windowPolicy:tabPlacementHint:forSearch:inNewProcess:profileIdentifier:, _goToRequest:tabLabel:windowPolicy:tabPlacementHint:forSearch:inNewProcess:profileIdentifier:, _isNewTabDefaultForWindowUserTabbingPreference, _newTabInCurrentContext:browsingMode:sender:, _newTabInNewWindowWithBrowsingMode:sender:, _restoreWebAppDocumentFromWindowState:reusingDocument:forTabGroup:mainWindow:selectedWindowMapping:, _setUpNewTabOrWindowMenuItem:addOptionFlagModifier:, _tabGroupWithUUID:, anyInactiveTabs, canCreateNewTab, createNewTabForAppIntentsInPrivateBrowsing:, goToCloudTab:tabLabel:windowPolicy:tabPlacementHint:
PROBE   ivars naming a store or a profile: _hasRestoredWebAppDocuments  B | _frontmostProfileIdentifier  @"NSString" | _preferredProfileIdentifierForNewDocument  @"NSString"
PROBE BrowserDocument: BrowserDocument <- NSDocument <- NSObject
PROBE   233 instance methods, 1 class methods, 13 ivars, 18 properties
PROBE   *init*: _commonBrowserDocumentInitWithContentsOfRequest:browserViewController:, _commonInitWithRequest:browsingMode:isPopupWindow:, displayInitialContents, hasInitialContents, init, initWithBrowsingMode:configuration:profileIdentifier:isPopupWindow:restoringFromLastSession:, initWithContentsOfRequest:browsingMode:profileIdentifier:automationSessionIdentifier:isPopupWindow:, initWithContentsOfURL:ofType:
PROBE   *window*: _commonInitWithRequest:browsingMode:isPopupWindow:, _openURL:withWindowPolicy:, _selectedTabsInWindow, browserWindowController, initWithBrowsingMode:configuration:profileIdentifier:isPopupWindow:restoringFromLastSession:, initWithContentsOfRequest:browsingMode:profileIdentifier:automationSessionIdentifier:isPopupWindow:, isPopupWindow, makeWindowControllers, pageCollectionControllerWindowWillClose:, profileDisplayTitleInWindow, removeWindowController:, restoreDocumentWindowWithIdentifier:state:completionHandler:, setProfileDisplayTitleInWindow:, setShouldOpenWindowBehindFrontmost:
PROBE   *profile*: getBytecodeProfile:, initWithBrowsingMode:configuration:profileIdentifier:isPopupWindow:restoringFromLastSession:, initWithContentsOfRequest:browsingMode:profileIdentifier:automationSessionIdentifier:isPopupWindow:, profileDisplayTitleInWindow, profileIdentifier, saveSamplingProfilerOutput:, setProfileDisplayTitleInWindow:, validate_getBytecodeProfile:, validate_saveSamplingProfilerOutput:
PROBE   *configuration*: initWithBrowsingMode:configuration:profileIdentifier:isPopupWindow:restoringFromLastSession:, makeBrowserViewControllerWithConfiguration:
PROBE   *new*: goToRequest:withTabLabel:inNewProcess:, setSuppressRelatingNewBlankTabs:, updateNewTabPositionValue:, validate_setSuppressRelatingNewBlankTabs:, validate_updateNewTabPositionValue:
PROBE   *tab*: _addBookmarksForTabViewItems:, _addReadingListItemsForTabs:, _numberOfTabsToPotentiallyAddToBookmarksOrReadingList, _selectedTabsInWindow, addBookmarksForTabs:, addReadingListItemsForTabs:, canAddBookmarksForTabs, canAddBookmarksForTabs:, currentBrowserViewControllerIgnoringVisualTabPickerVisibility, firstTabOpensWithStartPage, goToRequest:withTabLabel:, goToRequest:withTabLabel:inNewProcess:, isConsolidatable, setApplyPositionToAllBlankTabs:
PROBE   ivars naming a store or a profile: _profileIdentifier  @"NSString" | _profileDisplayTitleInWindow  @"NSString"
PROBE wrote framework-BrowserDocumentController.txt (18012 bytes)
PROBE step documentcontroller finished
2026-10-29 08:19:33.119 PrivacyBrowser[3518:14515] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:33.120 PrivacyBrowser[3518:14515] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:33.120 PrivacyBrowser[3518:14515] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:33.120 PrivacyBrowser[3518:14515] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:33.128 PrivacyBrowser[3518:14515] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## documentcontroller-create — exited 0

```
PROBE step documentcontroller-create
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads true; arguments YES, app 1, registered unset
PROBE chain: BrowserDocumentController <- NSDocumentController <- NSObject
PROBE declares -init: true, -_commonInit: true
PROBE declares +sharedDocumentController: true
PROBE a document controller exists before we ask: this step is about to find out
PROBE +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> nil
PROBE NSDocumentController.shared is NSDocumentController
PROBE step documentcontroller-create finished
2026-10-29 08:19:33.637 PrivacyBrowser[3519:14520] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:33.639 PrivacyBrowser[3519:14520] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:33.640 PrivacyBrowser[3519:14520] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:33.640 PrivacyBrowser[3519:14520] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:33.648 PrivacyBrowser[3519:14520] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## webconfig — exited 0

```
PROBE step webconfig
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE configuration factories: _webViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:relatedWebView:groupIdentifier:preferences:userContentController:jitEnabled:preferencesManager:, _webViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:relatedWebView:groupIdentifier:preferences:userContentController:webExtensionsController:jitEnabled:preferencesManager:, automationPreferencesWithConfiguration:, contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:, contentWebViewConfigurationForBrowsingMode:profileIdentifier:jitEnabled:, readerWebViewConfigurationForBrowsingMode:profileIdentifier:relatedWebView:, webExtensionWebViewConfigurationForExtension:, webExtensionWebViewConfigurationForExtensionsController:
PROBE calling +[WebKitPreferencesManager contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:] for profile 7955B067-F8A2-4F3D-8970-0E3EB5C770D6 …
PROBE   contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier: -> WKWebViewConfiguration
PROBE   websiteDataStore: persistent 7955B067-F8A2-4F3D-8970-0E3EB5C770D6
PROBE with the profile's store bound: contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier: -> WKWebViewConfiguration
PROBE   per-profile store factory asked for 05223FDF-DD54-4184-8444-8EE43088C996 -> handed it non-persistent
PROBE   websiteDataStore is the bound one: true
PROBE step webconfig finished
2026-10-29 08:19:33.694 PrivacyBrowser[3527:14629] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:33.695 PrivacyBrowser[3527:14629] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:33.695 PrivacyBrowser[3527:14629] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:33.695 PrivacyBrowser[3527:14629] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:33.713 PrivacyBrowser[3527:14629] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:33.905 PrivacyBrowser[3527:14629] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:19:33.905 PrivacyBrowser[3527:14629] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
```

## shared — exited 0

```
PROBE step shared
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads true; arguments YES, app 1, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads true; arguments YES, app 1, registered unset
PROBE AppController class-side singletons: sharedAppController
PROBE sending +[AppController sharedAppController] …
PROBE   sharedAppController -> nil
PROBE BrowserApplicationController -> nil
PROBE SafariApplicationController -> nil
PROBE step shared finished
2026-10-29 08:19:33.935 PrivacyBrowser[3529:14675] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:33.935 PrivacyBrowser[3529:14675] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:33.935 PrivacyBrowser[3529:14675] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:33.936 PrivacyBrowser[3529:14675] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:33.950 PrivacyBrowser[3529:14675] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:33.952 PrivacyBrowser[3529:14675] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:19:33.952 PrivacyBrowser[3529:14675] SafariWindow: +sharedDocumentController is now BrowserDocumentController
```

## create-direct — killed by SIGTRAP

```
PROBE step create-direct
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads true; arguments YES, app 1, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads true; arguments YES, app 1, registered unset
PROBE document controller created: BrowserDocumentController; +sharedDocumentController is BrowserDocumentController
PROBE initialisers it declares: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
PROBE allocating BrowserWindowController …
PROBE instance: BrowserWindowController
PROBE asking for -window (this is what loads the nib) …
2026-10-29 08:19:34.059 PrivacyBrowser[3530:14688] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:34.060 PrivacyBrowser[3530:14688] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:34.060 PrivacyBrowser[3530:14688] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:34.060 PrivacyBrowser[3530:14688] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:34.084 PrivacyBrowser[3530:14688] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:34.085 PrivacyBrowser[3530:14688] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:19:34.085 PrivacyBrowser[3530:14688] SafariWindow: +sharedDocumentController is now BrowserDocumentController
```

Crash report `PrivacyBrowser-2026-10-29-082005.0002.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:20:05.00 +0000",
    "app_version": "0.1.0",
    "slice_uuid": "4bf1a461-0de2-3603-a83b-42847697e57f",
    "build_version": "1",
    "platform": 1,
    "bundleID": "dev.local.PrivacyBrowser",
    "share_with_app_devs": 0,
    "is_first_party": 0,
    "bug_type": "309",
    "os_version": "macOS 26.6.2 (25G83)",
    "roots_installed": 0,
    "name": "PrivacyBrowser",
    "incident_id": "7F2215B0-EB31-4622-B017-C8A3324620A3"
  },
  "exception": {
    "codes": "0x0000000000000001, 0x000000018d86b6b4",
    "rawCodes": [
      1,
      6669383348
    ],
    "type": "EXC_BREAKPOINT",
    "signal": "SIGTRAP"
  },
  "termination": {
    "flags": 0,
    "code": 5,
    "namespace": "SIGNAL",
    "indicator": "Trace/BPT trap: 5",
    "byProc": "exc handler",
    "byPid": 3530
  },
  "faultingThread": 0,
  "triggered_frames": [
    "AppKit + 8513204",
    "AppKit + 5413880",
    "AppKit + 5414380",
    "AppKit + 14078072",
    "AppKit + 500440",
    "AppKit + 519184",
    "AppKit + 14036332",
    "AppKit + 500440",
    "AppKit + 519076",
    "AppKit + 14039356",
    "AppKit + 500440",
    "AppKit + 518016",
    "AppKit + 500440",
    "AppKit + 517904",
    "Safari + 138872",
    "AppKit + 1683880",
    "Safari + 137808",
    "AppKit + 1667980",
    "PrivacyBrowser + 1996500",
    "PrivacyBrowser + 2068000",
    "PrivacyBrowser + 2068000",
    "PrivacyBrowser + 2014340",
    "PrivacyBrowser + 2039389",
    "PrivacyBrowser + 2802481"
  ]
}
```

## create — killed by SIGTRAP

```
PROBE step create
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads true; arguments YES, app 1, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads true; arguments YES, app 1, registered unset
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
PROBE   [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
PROBE   window controller: BrowserWindowController
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000104d4fba4 PBPreprocessException + 48
PROBE     2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
PROBE     3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
PROBE     4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
PROBE     5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
PROBE     6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
PROBE     7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
PROBE     8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
PROBE     9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
PROBE     10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
PROBE     11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
PROBE     12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
PROBE     14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
PROBE     15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
PROBE     17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
PROBE     18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
PROBE     20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
PROBE     22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
PROBE     23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
PROBE     24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
PROBE     25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
PROBE     26  PrivacyBrowser                      0x0000000104e676d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
PROBE     27  PrivacyBrowser                      0x0000000104e5bc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     28  PrivacyBrowser                      0x0000000104e5fcb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     29  PrivacyBrowser                      0x0000000104e63dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     30  PrivacyBrowser                      0x0000000104cfcf90 $sIeg_IeyB_TR + 28
PROBE     31  PrivacyBrowser                      0x0000000104d4fa08 PBCatchException + 36
PROBE     32  PrivacyBrowser                      0x0000000104e5b990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     33  PrivacyBrowser                      0x0000000104e589ac $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1504
PROBE     34  PrivacyBrowser                      0x0000000104e6c740 $s14PrivacyBrowser20SafariFrameworkProbeO10createStep33_9F0153DCAF2CE7EC9F01CEB735D44942LL9bootstrapySb_tFZ + 468
PROBE     35  PrivacyBrowser                      0x0000000104e6bc84 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TY0_ + 500
PROBE     36  PrivacyBrowser                      0x0000000104e71e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     37  PrivacyBrowser                      0x0000000104f2c331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     38  PrivacyBrowser                      0x0000000104f2c319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     39  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:19:44.701 PrivacyBrowser[3692:15339] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:44.701 PrivacyBrowser[3692:15339] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:44.702 PrivacyBrowser[3692:15339] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:44.702 PrivacyBrowser[3692:15339] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:44.738 PrivacyBrowser[3692:15339] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:44.739 PrivacyBrowser[3692:15339] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:19:44.739 PrivacyBrowser[3692:15339] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:19:44.974 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:19:44.974 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]: document controller: BrowserDocumentController
2026-10-29 08:19:44.975 PrivacyBrowser[3692:15339] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:19:44.975 PrivacyBrowser[3692:15339] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:19:44.976 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]: BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
2026-10-29 08:19:44.979 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]: [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
2026-10-29 08:19:44.979 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]: window controller: BrowserWindowController
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   1   PrivacyBrowser                      0x0000000104d4fba4 PBPreprocessException + 48
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   26  PrivacyBrowser                      0x0000000104e676d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   27  PrivacyBrowser                      0x0000000104e5bc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   28  PrivacyBrowser                      0x0000000104e5fcb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   29  PrivacyBrowser                      0x0000000104e63dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   30  PrivacyBrowser                      0x0000000104cfcf90 $sIeg_IeyB_TR + 28
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   31  PrivacyBrowser                      0x0000000104d4fa08 PBCatchException + 36
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   32  PrivacyBrowser                      0x0000000104e5b990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   33  PrivacyBrowser                      0x0000000104e589ac $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1504
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   34  PrivacyBrowser                      0x0000000104e6c740 $s14PrivacyBrowser20SafariFrameworkProbeO10createStep33_9F0153DCAF2CE7EC9F01CEB735D44942LL9bootstrapySb_tFZ + 468
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   35  PrivacyBrowser                      0x0000000104e6bc84 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TY0_ + 500
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   36  PrivacyBrowser                      0x0000000104e71e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   37  PrivacyBrowser                      0x0000000104f2c331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   38  PrivacyBrowser                      0x0000000104f2c319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
2026-10-29 08:19:45.571 PrivacyBrowser[3692:15339] SafariWindow[B9ED7FBF]:   39  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
```

Crash report `PrivacyBrowser-2026-10-29-082005.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:20:05.00 +0000",
    "app_version": "0.1.0",
    "slice_uuid": "4bf1a461-0de2-3603-a83b-42847697e57f",
    "build_version": "1",
    "platform": 1,
    "bundleID": "dev.local.PrivacyBrowser",
    "share_with_app_devs": 0,
    "is_first_party": 0,
    "bug_type": "309",
    "os_version": "macOS 26.6.2 (25G83)",
    "roots_installed": 0,
    "name": "PrivacyBrowser",
    "incident_id": "CBA5B683-5445-448E-9109-0026400FC841"
  },
  "exception": {
    "codes": "0x0000000000000001, 0x000000018d86b6b4",
    "rawCodes": [
      1,
      6669383348
    ],
    "type": "EXC_BREAKPOINT",
    "signal": "SIGTRAP"
  },
  "termination": {
    "flags": 0,
    "code": 5,
    "namespace": "SIGNAL",
    "indicator": "Trace/BPT trap: 5",
    "byProc": "exc handler",
    "byPid": 3692
  },
  "faultingThread": 0,
  "triggered_frames": [
    "AppKit + 8513204",
    "AppKit + 5413880",
    "AppKit + 5414380",
    "AppKit + 14078072",
    "AppKit + 500440",
    "AppKit + 519184",
    "AppKit + 14036332",
    "AppKit + 500440",
    "AppKit + 519076",
    "AppKit + 14039356",
    "AppKit + 500440",
    "AppKit + 518016",
    "AppKit + 500440",
    "AppKit + 517904",
    "Safari + 138872",
    "AppKit + 1683880",
    "Safari + 137808",
    "AppKit + 1667980",
    "PrivacyBrowser + 1996500",
    "PrivacyBrowser + 1948684",
    "PrivacyBrowser + 1948684",
    "PrivacyBrowser + 1965240",
    "PrivacyBrowser + 1981884",
    "PrivacyBrowser + 511888"
  ]
}
```

## create-bootstrap — killed by SIGTRAP

```
PROBE step create-bootstrap
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads true; arguments YES, app 1, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads true; arguments YES, app 1, registered unset
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
PROBE   [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
PROBE   window controller: BrowserWindowController
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x000000010098fba4 PBPreprocessException + 48
PROBE     2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
PROBE     3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
PROBE     4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
PROBE     5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
PROBE     6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
PROBE     7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
PROBE     8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
PROBE     9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
PROBE     10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
PROBE     11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
PROBE     12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
PROBE     14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
PROBE     15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
PROBE     17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
PROBE     18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
PROBE     20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
PROBE     22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
PROBE     23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
PROBE     24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
PROBE     25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
PROBE     26  PrivacyBrowser                      0x0000000100aa76d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
PROBE     27  PrivacyBrowser                      0x0000000100a9bc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     28  PrivacyBrowser                      0x0000000100a9fcb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     29  PrivacyBrowser                      0x0000000100aa3dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     30  PrivacyBrowser                      0x000000010093cf90 $sIeg_IeyB_TR + 28
PROBE     31  PrivacyBrowser                      0x000000010098fa08 PBCatchException + 36
PROBE     32  PrivacyBrowser                      0x0000000100a9b990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     33  PrivacyBrowser                      0x0000000100a989ac $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1504
PROBE     34  PrivacyBrowser                      0x0000000100aac740 $s14PrivacyBrowser20SafariFrameworkProbeO10createStep33_9F0153DCAF2CE7EC9F01CEB735D44942LL9bootstrapySb_tFZ + 468
PROBE     35  PrivacyBrowser                      0x0000000100aabc84 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TY0_ + 500
PROBE     36  PrivacyBrowser                      0x0000000100ab1e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     37  PrivacyBrowser                      0x0000000100b6c331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     38  PrivacyBrowser                      0x0000000100b6c319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     39  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:19:54.951 PrivacyBrowser[3921:16205] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:54.952 PrivacyBrowser[3921:16205] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:54.952 PrivacyBrowser[3921:16205] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:54.952 PrivacyBrowser[3921:16205] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:55.083 PrivacyBrowser[3921:16205] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:55.084 PrivacyBrowser[3921:16205] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:19:55.084 PrivacyBrowser[3921:16205] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:19:55.300 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:19:55.301 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]: document controller: BrowserDocumentController
2026-10-29 08:19:55.301 PrivacyBrowser[3921:16205] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:19:55.301 PrivacyBrowser[3921:16205] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:19:55.305 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]: BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
2026-10-29 08:19:55.309 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]: [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
2026-10-29 08:19:55.309 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]: window controller: BrowserWindowController
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   1   PrivacyBrowser                      0x000000010098fba4 PBPreprocessException + 48
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   26  PrivacyBrowser                      0x0000000100aa76d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   27  PrivacyBrowser                      0x0000000100a9bc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   28  PrivacyBrowser                      0x0000000100a9fcb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   29  PrivacyBrowser                      0x0000000100aa3dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   30  PrivacyBrowser                      0x000000010093cf90 $sIeg_IeyB_TR + 28
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   31  PrivacyBrowser                      0x000000010098fa08 PBCatchException + 36
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   32  PrivacyBrowser                      0x0000000100a9b990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   33  PrivacyBrowser                      0x0000000100a989ac $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1504
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   34  PrivacyBrowser                      0x0000000100aac740 $s14PrivacyBrowser20SafariFrameworkProbeO10createStep33_9F0153DCAF2CE7EC9F01CEB735D44942LL9bootstrapySb_tFZ + 468
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   35  PrivacyBrowser                      0x0000000100aabc84 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TY0_ + 500
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   36  PrivacyBrowser                      0x0000000100ab1e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   37  PrivacyBrowser                      0x0000000100b6c331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   38  PrivacyBrowser                      0x0000000100b6c319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
2026-10-29 08:19:55.611 PrivacyBrowser[3921:16205] SafariWindow[A48684FD]:   39  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
```

## window — killed by SIGTRAP

```
PROBE step window
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads true; arguments YES, app 1, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads true; arguments YES, app 1, registered unset
PROBE profile store: persistent D388491F-EE64-48A8-A54A-37F61D54215D
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
PROBE   [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
PROBE   window controller: BrowserWindowController
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x000000010504fba4 PBPreprocessException + 48
PROBE     2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
PROBE     3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
PROBE     4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
PROBE     5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
PROBE     6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
PROBE     7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
PROBE     8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
PROBE     9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
PROBE     10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
PROBE     11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
PROBE     12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
PROBE     14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
PROBE     15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
PROBE     17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
PROBE     18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
PROBE     20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
PROBE     22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
PROBE     23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
PROBE     24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
PROBE     25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
PROBE     26  PrivacyBrowser                      0x00000001051676d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
PROBE     27  PrivacyBrowser                      0x000000010515bc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     28  PrivacyBrowser                      0x000000010515fcb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     29  PrivacyBrowser                      0x0000000105163dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     30  PrivacyBrowser                      0x0000000104ffcf90 $sIeg_IeyB_TR + 28
PROBE     31  PrivacyBrowser                      0x000000010504fa08 PBCatchException + 36
PROBE     32  PrivacyBrowser                      0x000000010515b990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     33  PrivacyBrowser                      0x00000001051589ac $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1504
PROBE     34  PrivacyBrowser                      0x000000010516cfb0 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZ04$s14a9Browser20cde17O10windowStep33_9ijklmno11LLyyYaFZSo8p10CSgAA0cB16qr6C_So18stU24C10Foundation3URLVtXEfU_Tf1cn_nTY0_ + 1092
PROBE     35  PrivacyBrowser                      0x000000010516bf49 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ5_ + 1
PROBE     36  PrivacyBrowser                      0x0000000105171e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     37  PrivacyBrowser                      0x000000010522c331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     38  PrivacyBrowser                      0x000000010522c319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     39  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:20:04.768 PrivacyBrowser[4128:16880] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:04.769 PrivacyBrowser[4128:16880] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:04.769 PrivacyBrowser[4128:16880] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:04.769 PrivacyBrowser[4128:16880] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:04.839 PrivacyBrowser[4128:16880] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:20:04.840 PrivacyBrowser[4128:16880] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:20:04.840 PrivacyBrowser[4128:16880] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:20:05.284 PrivacyBrowser[4128:16880] SafariWindow[D388491F]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:20:05.285 PrivacyBrowser[4128:16880] SafariWindow[D388491F]: document controller: BrowserDocumentController
2026-10-29 08:20:05.285 PrivacyBrowser[4128:16880] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:20:05.285 PrivacyBrowser[4128:16880] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:20:05.287 PrivacyBrowser[4128:16880] SafariWindow[D388491F]: BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
2026-10-29 08:20:05.291 PrivacyBrowser[4128:16880] SafariWindow[D388491F]: [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
2026-10-29 08:20:05.292 PrivacyBrowser[4128:16880] SafariWindow[D388491F]: window controller: BrowserWindowController
2026-10-29 08:20:06.281 PrivacyBrowser[4128:16880] SafariWindow[D388491F]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:20:06.281 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:20:06.281 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   1   PrivacyBrowser                      0x000000010504fba4 PBPreprocessException + 48
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   26  PrivacyBrowser                      0x00000001051676d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   27  PrivacyBrowser                      0x000000010515bc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   28  PrivacyBrowser                      0x000000010515fcb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   29  PrivacyBrowser                      0x0000000105163dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   30  PrivacyBrowser                      0x0000000104ffcf90 $sIeg_IeyB_TR + 28
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   31  PrivacyBrowser                      0x000000010504fa08 PBCatchException + 36
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   32  PrivacyBrowser                      0x000000010515b990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   33  PrivacyBrowser                      0x00000001051589ac $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1504
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   34  PrivacyBrowser                      0x000000010516cfb0 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZ04$s14a9Browser20cde17O10windowStep33_9ijklmno11LLyyYaFZSo8p10CSgAA0cB16qr6C_So18stU24C10Foundation3URLVtXEfU_Tf1cn_nTY0_ + 1092
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   35  PrivacyBrowser                      0x000000010516bf49 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ5_ + 1
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   36  PrivacyBrowser                      0x0000000105171e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   37  PrivacyBrowser                      0x000000010522c331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   38  PrivacyBrowser                      0x000000010522c319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
2026-10-29 08:20:06.282 PrivacyBrowser[4128:16880] SafariWindow[D388491F]:   39  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
```

Crash report `PrivacyBrowser-2026-10-29-082009.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:20:09.00 +0000",
    "app_version": "0.1.0",
    "slice_uuid": "4bf1a461-0de2-3603-a83b-42847697e57f",
    "build_version": "1",
    "platform": 1,
    "bundleID": "dev.local.PrivacyBrowser",
    "share_with_app_devs": 0,
    "is_first_party": 0,
    "bug_type": "309",
    "os_version": "macOS 26.6.2 (25G83)",
    "roots_installed": 0,
    "name": "PrivacyBrowser",
    "incident_id": "EA7643A3-559C-4B37-8C89-2083FCB09693"
  },
  "exception": {
    "codes": "0x0000000000000001, 0x000000018d86b6b4",
    "rawCodes": [
      1,
      6669383348
    ],
    "type": "EXC_BREAKPOINT",
    "signal": "SIGTRAP"
  },
  "termination": {
    "flags": 0,
    "code": 5,
    "namespace": "SIGNAL",
    "indicator": "Trace/BPT trap: 5",
    "byProc": "exc handler",
    "byPid": 4128
  },
  "faultingThread": 0,
  "triggered_frames": [
    "AppKit + 8513204",
    "AppKit + 5413880",
    "AppKit + 5414380",
    "AppKit + 14078072",
    "AppKit + 500440",
    "AppKit + 519184",
    "AppKit + 14036332",
    "AppKit + 500440",
    "AppKit + 519076",
    "AppKit + 14039356",
    "AppKit + 500440",
    "AppKit + 518016",
    "AppKit + 500440",
    "AppKit + 517904",
    "Safari + 138872",
    "AppKit + 1683880",
    "Safari + 137808",
    "AppKit + 1667980",
    "PrivacyBrowser + 1996500",
    "PrivacyBrowser + 1948684",
    "PrivacyBrowser + 1948684",
    "PrivacyBrowser + 1965240",
    "PrivacyBrowser + 1981884",
    "PrivacyBrowser + 511888"
  ]
}
```

## popupfield — exited 0

```
PROBE step popupfield
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE UnifiedField: UnifiedField <- NSTextField <- NSControl <- NSView <- NSResponder <- NSObject; a UnifiedField: true
PROBE   -_notSecureAnnotation: declared here
PROBE   -_layOutFaviconAndMainContentView: declared here
PROBE   -layout: declared here
PROBE PopupWindowUnifiedField: PopupWindowUnifiedField <- UnifiedField <- NSTextField <- NSControl <- NSView <- NSResponder <- NSObject; a UnifiedField: true
PROBE   -_notSecureAnnotation: inherited, UnifiedField's own implementation
PROBE   -_layOutFaviconAndMainContentView: inherited, UnifiedField's own implementation
PROBE   -layout: inherited, UnifiedField's own implementation
PROBE InteriorUnifiedField: InteriorUnifiedField <- NSTextField <- NSControl <- NSView <- NSResponder <- NSObject; a UnifiedField: false
PROBE   -_notSecureAnnotation: not implemented
PROBE   -_layOutFaviconAndMainContentView: not implemented
PROBE   -layout: inherited
PROBE PopupWindowUnifiedFieldContainerView: PopupWindowUnifiedFieldContainerView <- NSView <- NSResponder <- NSObject; a UnifiedField: false
PROBE   -_notSecureAnnotation: not implemented
PROBE   -_layOutFaviconAndMainContentView: not implemented
PROBE   -layout: inherited
PROBE PopupWindowUnifiedFieldViewController: PopupWindowUnifiedFieldViewController <- NSTitlebarAccessoryViewController <- NSViewController <- NSResponder <- NSObject; a UnifiedField: false
PROBE   -_notSecureAnnotation: not implemented
PROBE   -_layOutFaviconAndMainContentView: not implemented
PROBE   -layout: not implemented
PROBE classes to dump: PopupWindowUnifiedField, PopupWindowUnifiedFieldViewController, BrowserViewController
PROBE PopupWindowUnifiedField: PopupWindowUnifiedField <- UnifiedField <- NSTextField <- NSControl <- NSView <- NSResponder <- NSObject
PROBE   25 instance methods, 1 class methods, 1 ivars, 1 properties
PROBE   *init*: _commonInitialization, initWithCoder:, initWithFrame:
PROBE   *window*: _windowChangedKeyState, mouseDownCanMoveWindow
PROBE   ivars naming a store or a profile: none
PROBE PopupWindowUnifiedFieldViewController: PopupWindowUnifiedFieldViewController <- NSTitlebarAccessoryViewController <- NSViewController <- NSResponder <- NSObject
PROBE   8 instance methods, 0 class methods, 2 ivars, 1 properties
PROBE   *init*: initWithNibName:bundle:
PROBE   *window*: popupWindowUnifiedField, setPopupWindowUnifiedField:
PROBE   ivars naming a store or a profile: none
PROBE BrowserViewController: BrowserViewController <- WebViewController <- NSViewController <- NSResponder <- NSObject
PROBE   1266 instance methods, 10 class methods, 295 ivars, 323 properties
PROBE   *init*: _abortInitiateLoad, _commonInitializationWithDocument:, _didStartBrowserInitiatedLoadUsingBackForwardList:, _hideTransientBannerDueToUserInitiatedNavigationOrVisuallyNonEmptyLayout, _initializeScribbleOut, _initiateLoad, _initiateQueuedNavigation, _performPrefillingWorkWithFormMetadataProvider:isInitialCollectionAtPageLoad:, _tryToInitiateLoad:initiateLoadBlock:, alwaysInitiateLoadsInContinuousModeUsingCurrentController, clearPendingBrowserInitiatedLoad, didCollectMetadataForPrefillingFormInFrames:metadataForAllForms:isInitialCollectionAtPageLoad:, didCollectMetadataFromInjectedBundleForPrefillingFormInFrames:metadataForAllForms:isInitialCollectionAtPageLoad:, displayInitialContents
PROBE   *window*: _addDomainToAllowedPopUpWindowDomainCache:, _selectTabViewItem:inWindowController:cancelIfInvalid:, _simulateKeysToTypeTextInToBrowserView:textToType:characterIndex:windowNumber:shouldSendReturnKeyEvent:, _updateWKViewLayoutModeForWindow:, _windowCanBeResized:, _windowContentSplitViewController, _windowPolicyForCreateBrowserViewController, addBlockedPopUpWindowConfiguration:, announceIfLinkOpenedInNewTabOrWindowWithVoiceOverLinkPolicy:, announceIfLinkOpenedInNewTabOrWindowWithWindowPolicy:, bringTabAndWindowToFront, bringTabAndWindowToFrontForUserNotification:, browserViewDidMoveToWindow, browserViewWillMoveToWindow:
PROBE   *profile*: isWaitingForBytecodeProfile, isWaitingForSamplingProfilerOutput, profile, setWaitingForBytecodeProfile:, setWaitingForSamplingProfilerOutput:
PROBE   *webview*: _createWebViewWithConfiguration:, _handleCertificateError:forWebView:isMainFrame:, _handleErrorForWebView:isMainFrame:pageLoadType:error:getIsTryingFallbackURLs:, _installAlternativeWebViewFunctionBarProvider:, _installWebView, _startObservingWKWebViewKeyValueChanges, _stopObservingWKWebViewKeyValueChanges, _uninstallAlternativeWebViewFunctionBarProvider, _webView:storeAppHighlight:inNewGroup:requestOriginatedInApp:, createContentViewController, initWithDefaultWebViewConfigurationWithDocument:browsingMode:, isShowingWebView, locationChangeDoneForWebView:isMainFrame:pageLoadType:error:, readerWebViewDidScroll
PROBE   *configuration*: _createWebViewWithConfiguration:, addBlockedPopUpWindowConfiguration:, assistantReaderCardConfigurationManager, clearBlockedWindowConfigurationCaches, createBrowserViewControllerFromWindowConfiguration:, duplicateUsingConfiguration:forWebExtensionContext:completionHandler:, initWithDefaultWebViewConfigurationWithDocument:browsingMode:, initWithDocument:configuration:browsingMode:, openWindowWithConfiguration:, presentTabDialogWithConfiguration:dismissalBlock:blocksWebProcessUntilDismissed:cancellationExemptions:, readerConfigurationChanged, setAssistantReaderCardConfigurationManager:
PROBE   *new*: _createNewExtensionBannerIfNecessary, _loadQueuedNavigationWithURLRequest:shouldLoadInNewProcess:, _loadURLRequest:tabLabel:lifetime:allowJavaScript:waitInQueue:clearFallbackURLs:inNewProcess:skipSyncableTabUpdates:canAttemptUpgradingRequestURLToHTTPS:searchNavigationUUID:, _webView:storeAppHighlight:inNewGroup:requestOriginatedInApp:, addNavigationNeedingNewProcess:, announceIfLinkOpenedInNewTabOrWindowWithVoiceOverLinkPolicy:, announceIfLinkOpenedInNewTabOrWindowWithWindowPolicy:, browserWKViewDidMoveToNewWindow, didSaveNewSavedAccountWithGeneratedPassword:, fireReplacedEventToExtensionsIfNecessaryWithNewBrowserViewController:, hideNewExtensionBannerAnimated:, loadURL:tabLabel:httpReferrer:inNewProcess:canAttemptUpgradingRequestURLToHTTPS:additionalHeaderFields:searchNavigationUUID:, loadURL:tabLabel:httpReferrer:inNewProcess:canAttemptUpgradingRequestURLToHTTPS:searchNavigationUUID:, loadURLRequest:tabLabel:inNewProcess:canAttemptUpgradingRequestURLToHTTPS:searchNavigationUUID:
PROBE   *tab*: _addSpawnedTabBrowserViewController:, _canPersistTabs, _defaultDatabaseQuota, _didDismissTabDialogs, _enqueueRestoredNavigation:withTabState:, _isAutoSelectableWithURL:, _isOnlyTabInWebProcessThatIsShowingWebContent, _loadURLRequest:tabLabel:lifetime:allowJavaScript:waitInQueue:clearFallbackURLs:inNewProcess:skipSyncableTabUpdates:canAttemptUpgradingRequestURLToHTTPS:searchNavigationUUID:, _pageMutableMediaState, _removeSpawnedTabBrowserViewController:, _removeTabFromCoreSpotlight, _restoreTabIdentifiersWithPersistentTabState:, _returnToParentTabAndOptionallyCloseTab:, _selectTabViewItem:inWindowController:cancelIfInvalid:
PROBE   ivars naming a store or a profile: _contentBlockerStatisticsStore  @"<WBSContentBlockerStatisticsStore>" | _profileIdentifierForExtensions  @"NSString" | _waitingForSamplingProfilerOutput  B | _waitingForBytecodeProfile  B | _pendingTabStateToRestore  @"BrowserTabPersistentState" | _sessionStateToRestoreAfterFinishingNavigation  {SessionState="m_webKit2Object"{WKRetainPtr<const void *>="m_ptr"^v}}
PROBE wrote framework-PopupWindowUnifiedField.txt (100439 bytes)
PROBE step popupfield finished
2026-10-29 08:20:15.432 PrivacyBrowser[4733:18497] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:15.433 PrivacyBrowser[4733:18497] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:15.433 PrivacyBrowser[4733:18497] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:15.433 PrivacyBrowser[4733:18497] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:15.496 PrivacyBrowser[4733:18497] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## popup — killed by SIGTRAP

```
PROBE step popup
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments unset, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments unset, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments unset, app unset, registered unset
PROBE profile store: persistent 9D4ADB0F-AE0B-4FDA-9828-FF6A896EB7A2
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup
PROBE   NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
PROBE   [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x00000001028d3ba4 PBPreprocessException + 48
PROBE     2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
PROBE     3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
PROBE     4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
PROBE     5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
PROBE     6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
PROBE     7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
PROBE     8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
PROBE     9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
PROBE     10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
PROBE     11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
PROBE     12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
PROBE     14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
PROBE     15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
PROBE     17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
PROBE     18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
PROBE     20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
PROBE     22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
PROBE     23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
PROBE     24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
PROBE     25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
PROBE     26  PrivacyBrowser                      0x00000001029eb6d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
PROBE     27  PrivacyBrowser                      0x00000001029dfc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     28  PrivacyBrowser                      0x00000001029e3cb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     29  PrivacyBrowser                      0x00000001029e7dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     30  PrivacyBrowser                      0x0000000102880f90 $sIeg_IeyB_TR + 28
PROBE     31  PrivacyBrowser                      0x00000001028d3a08 PBCatchException + 36
PROBE     32  PrivacyBrowser                      0x00000001029df990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     33  PrivacyBrowser                      0x00000001029e2398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
PROBE     34  PrivacyBrowser                      0x00000001029de3a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
PROBE     35  PrivacyBrowser                      0x00000001029f52e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
PROBE     36  PrivacyBrowser                      0x00000001029f33e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
PROBE     37  PrivacyBrowser                      0x00000001029efdc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     38  PrivacyBrowser                      0x00000001029f5e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     39  PrivacyBrowser                      0x0000000102ab0331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     40  PrivacyBrowser                      0x0000000102ab0319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     41  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:20:15.640 PrivacyBrowser[4734:18501] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:15.640 PrivacyBrowser[4734:18501] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:15.640 PrivacyBrowser[4734:18501] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:15.640 PrivacyBrowser[4734:18501] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:15.657 PrivacyBrowser[4734:18501] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:20:15.659 PrivacyBrowser[4734:18501] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:20:15.659 PrivacyBrowser[4734:18501] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:20:15.918 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:20:15.918 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]: document controller: BrowserDocumentController
2026-10-29 08:20:15.918 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]: popup path, popup
2026-10-29 08:20:15.918 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]: NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
2026-10-29 08:20:15.919 PrivacyBrowser[4734:18501] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:20:15.919 PrivacyBrowser[4734:18501] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:20:15.920 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]: [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
2026-10-29 08:20:15.920 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:20:15.920 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   1   PrivacyBrowser                      0x00000001028d3ba4 PBPreprocessException + 48
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:20:16.281 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   26  PrivacyBrowser                      0x00000001029eb6d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   27  PrivacyBrowser                      0x00000001029dfc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   28  PrivacyBrowser                      0x00000001029e3cb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   29  PrivacyBrowser                      0x00000001029e7dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   30  PrivacyBrowser                      0x0000000102880f90 $sIeg_IeyB_TR + 28
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   31  PrivacyBrowser                      0x00000001028d3a08 PBCatchException + 36
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   32  PrivacyBrowser                      0x00000001029df990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   33  PrivacyBrowser                      0x00000001029e2398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   34  PrivacyBrowser                      0x00000001029de3a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   35  PrivacyBrowser                      0x00000001029f52e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   36  PrivacyBrowser                      0x00000001029f33e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   37  PrivacyBrowser                      0x00000001029efdc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   38  PrivacyBrowser                      0x00000001029f5e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   39  PrivacyBrowser                      0x0000000102ab0331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:20:16.282 PrivacyBrowser[4734:18501] SafariWindow[9D4ADB0F]:   40  PrivacyBrowser                      0x0000000102ab0319 $sxIeAgHr_xs5Error_pIegHrzo_s
```

Crash report `PrivacyBrowser-2026-10-29-082017.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:20:17.00 +0000",
    "app_version": "0.1.0",
    "slice_uuid": "4bf1a461-0de2-3603-a83b-42847697e57f",
    "build_version": "1",
    "platform": 1,
    "bundleID": "dev.local.PrivacyBrowser",
    "share_with_app_devs": 0,
    "is_first_party": 0,
    "bug_type": "309",
    "os_version": "macOS 26.6.2 (25G83)",
    "roots_installed": 0,
    "name": "PrivacyBrowser",
    "incident_id": "E9C2C778-0B7A-43E8-8B5B-296E3CC923AF"
  },
  "exception": {
    "codes": "0x0000000000000001, 0x000000018d86b6b4",
    "rawCodes": [
      1,
      6669383348
    ],
    "type": "EXC_BREAKPOINT",
    "signal": "SIGTRAP"
  },
  "termination": {
    "flags": 0,
    "code": 5,
    "namespace": "SIGNAL",
    "indicator": "Trace/BPT trap: 5",
    "byProc": "exc handler",
    "byPid": 4734
  },
  "faultingThread": 0,
  "triggered_frames": [
    "AppKit + 8513204",
    "AppKit + 5413880",
    "AppKit + 5414380",
    "AppKit + 14078072",
    "AppKit + 500440",
    "AppKit + 519184",
    "AppKit + 14036332",
    "AppKit + 500440",
    "AppKit + 519076",
    "AppKit + 14039356",
    "AppKit + 500440",
    "AppKit + 518016",
    "AppKit + 500440",
    "AppKit + 517904",
    "Safari + 138872",
    "AppKit + 1683880",
    "Safari + 137808",
    "AppKit + 1667980",
    "PrivacyBrowser + 1996500",
    "PrivacyBrowser + 1948684",
    "PrivacyBrowser + 1948684",
    "PrivacyBrowser + 1965240",
    "PrivacyBrowser + 1981884",
    "PrivacyBrowser + 511888"
  ]
}
```

## popup-nofield — killed by SIGTRAP

```
PROBE step popup-nofield
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments unset, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments unset, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments unset, app unset, registered unset
PROBE profile store: persistent 6D792C79-DA48-422A-B1F6-5A7D04E079B1
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup-nofield
PROBE   NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
PROBE   [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   setPopupWindowUnifiedFieldVisible:NO -> sent; isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000100ce7ba4 PBPreprocessException + 48
PROBE     2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
PROBE     3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
PROBE     4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
PROBE     5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
PROBE     6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
PROBE     7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
PROBE     8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
PROBE     9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
PROBE     10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
PROBE     11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
PROBE     12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
PROBE     14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
PROBE     15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
PROBE     17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
PROBE     18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
PROBE     20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
PROBE     22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
PROBE     23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
PROBE     24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
PROBE     25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
PROBE     26  PrivacyBrowser                      0x0000000100dff6d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
PROBE     27  PrivacyBrowser                      0x0000000100df3c0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     28  PrivacyBrowser                      0x0000000100df7cb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     29  PrivacyBrowser                      0x0000000100dfbdbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     30  PrivacyBrowser                      0x0000000100c94f90 $sIeg_IeyB_TR + 28
PROBE     31  PrivacyBrowser                      0x0000000100ce7a08 PBCatchException + 36
PROBE     32  PrivacyBrowser                      0x0000000100df3990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     33  PrivacyBrowser                      0x0000000100df6398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
PROBE     34  PrivacyBrowser                      0x0000000100df23a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
PROBE     35  PrivacyBrowser                      0x0000000100e092e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
PROBE     36  PrivacyBrowser                      0x0000000100e073e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
PROBE     37  PrivacyBrowser                      0x0000000100e03dc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     38  PrivacyBrowser                      0x0000000100e09e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     39  PrivacyBrowser                      0x0000000100ec4331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     40  PrivacyBrowser                      0x0000000100ec4319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     41  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:20:25.255 PrivacyBrowser[4753:18756] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:25.256 PrivacyBrowser[4753:18756] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:25.256 PrivacyBrowser[4753:18756] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:25.256 PrivacyBrowser[4753:18756] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:25.312 PrivacyBrowser[4753:18756] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:20:25.313 PrivacyBrowser[4753:18756] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:20:25.313 PrivacyBrowser[4753:18756] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:20:25.587 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:20:25.588 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]: document controller: BrowserDocumentController
2026-10-29 08:20:25.588 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]: popup path, popup-nofield
2026-10-29 08:20:25.588 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]: NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
2026-10-29 08:20:25.589 PrivacyBrowser[4753:18756] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:20:25.589 PrivacyBrowser[4753:18756] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:20:25.595 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]: [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
2026-10-29 08:20:25.596 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:20:25.596 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:20:25.596 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]: setPopupWindowUnifiedFieldVisible:NO -> sent; isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:20:25.975 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:20:25.975 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:20:25.975 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   1   PrivacyBrowser                      0x0000000100ce7ba4 PBPreprocessException + 48
2026-10-29 08:20:25.975 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:20:25.975 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:20:25.975 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:20:25.975 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
2026-10-29 08:20:25.975 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
2026-10-29 08:20:25.975 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
2026-10-29 08:20:25.975 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
2026-10-29 08:20:25.975 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
2026-10-29 08:20:25.975 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
2026-10-29 08:20:25.975 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
2026-10-29 08:20:25.975 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:25.975 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
2026-10-29 08:20:25.975 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   26  PrivacyBrowser                      0x0000000100dff6d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   27  PrivacyBrowser                      0x0000000100df3c0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   28  PrivacyBrowser                      0x0000000100df7cb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   29  PrivacyBrowser                      0x0000000100dfbdbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   30  PrivacyBrowser                      0x0000000100c94f90 $sIeg_IeyB_TR + 28
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   31  PrivacyBrowser                      0x0000000100ce7a08 PBCatchException + 36
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   32  PrivacyBrowser                      0x0000000100df3990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   33  PrivacyBrowser                      0x0000000100df6398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   34  PrivacyBrowser                      0x0000000100df23a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   35  PrivacyBrowser                      0x0000000100e092e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   36  PrivacyBrowser                      0x0000000100e073e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   37  PrivacyBrowser                      0x0000000100e03dc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] SafariWindow[6D792C79]:   38  PrivacyBrowser                      0x0000000100e09e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:20:25.976 PrivacyBrowser[4753:18756] S
```

Crash report `PrivacyBrowser-2026-10-29-082027.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:20:27.00 +0000",
    "app_version": "0.1.0",
    "slice_uuid": "4bf1a461-0de2-3603-a83b-42847697e57f",
    "build_version": "1",
    "platform": 1,
    "bundleID": "dev.local.PrivacyBrowser",
    "share_with_app_devs": 0,
    "is_first_party": 0,
    "bug_type": "309",
    "os_version": "macOS 26.6.2 (25G83)",
    "roots_installed": 0,
    "name": "PrivacyBrowser",
    "incident_id": "FA22D259-B525-4559-BC74-DEB039E53E1A"
  },
  "exception": {
    "codes": "0x0000000000000001, 0x000000018d86b6b4",
    "rawCodes": [
      1,
      6669383348
    ],
    "type": "EXC_BREAKPOINT",
    "signal": "SIGTRAP"
  },
  "termination": {
    "flags": 0,
    "code": 5,
    "namespace": "SIGNAL",
    "indicator": "Trace/BPT trap: 5",
    "byProc": "exc handler",
    "byPid": 4753
  },
  "faultingThread": 0,
  "triggered_frames": [
    "AppKit + 8513204",
    "AppKit + 5413880",
    "AppKit + 5414380",
    "AppKit + 14078072",
    "AppKit + 500440",
    "AppKit + 519184",
    "AppKit + 14036332",
    "AppKit + 500440",
    "AppKit + 519076",
    "AppKit + 14039356",
    "AppKit + 500440",
    "AppKit + 518016",
    "AppKit + 500440",
    "AppKit + 517904",
    "Safari + 138872",
    "AppKit + 1683880",
    "Safari + 137808",
    "AppKit + 1667980",
    "PrivacyBrowser + 1996500",
    "PrivacyBrowser + 1948684",
    "PrivacyBrowser + 1948684",
    "PrivacyBrowser + 1965240",
    "PrivacyBrowser + 1981884",
    "PrivacyBrowser + 511888"
  ]
}
```

## popup-mode — killed by SIGTRAP

```
PROBE step popup-mode
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments unset, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments unset, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments unset, app unset, registered unset
PROBE profile store: persistent 975CA96F-CC79-435A-804A-AFEF7E236C29
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup-mode
PROBE   NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
PROBE   [[BrowserWindowController alloc] initWithBrowsingMode:0 isPopupWindow:YES]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x000000010242fba4 PBPreprocessException + 48
PROBE     2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
PROBE     3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
PROBE     4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
PROBE     5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
PROBE     6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
PROBE     7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
PROBE     8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
PROBE     9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
PROBE     10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
PROBE     11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
PROBE     12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
PROBE     14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
PROBE     15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
PROBE     17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
PROBE     18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
PROBE     20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
PROBE     22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
PROBE     23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
PROBE     24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
PROBE     25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
PROBE     26  PrivacyBrowser                      0x00000001025476d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
PROBE     27  PrivacyBrowser                      0x000000010253bc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     28  PrivacyBrowser                      0x000000010253fcb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     29  PrivacyBrowser                      0x0000000102543dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     30  PrivacyBrowser                      0x00000001023dcf90 $sIeg_IeyB_TR + 28
PROBE     31  PrivacyBrowser                      0x000000010242fa08 PBCatchException + 36
PROBE     32  PrivacyBrowser                      0x000000010253b990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     33  PrivacyBrowser                      0x000000010253e398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
PROBE     34  PrivacyBrowser                      0x000000010253a3a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
PROBE     35  PrivacyBrowser                      0x00000001025512e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
PROBE     36  PrivacyBrowser                      0x000000010254f3e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
PROBE     37  PrivacyBrowser                      0x000000010254bdc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     38  PrivacyBrowser                      0x0000000102551e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     39  PrivacyBrowser                      0x000000010260c331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     40  PrivacyBrowser                      0x000000010260c319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     41  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:20:34.900 PrivacyBrowser[4969:19394] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:34.901 PrivacyBrowser[4969:19394] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:34.901 PrivacyBrowser[4969:19394] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:34.901 PrivacyBrowser[4969:19394] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:34.972 PrivacyBrowser[4969:19394] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:20:34.974 PrivacyBrowser[4969:19394] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:20:34.974 PrivacyBrowser[4969:19394] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:20:35.251 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:20:35.251 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]: document controller: BrowserDocumentController
2026-10-29 08:20:35.252 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]: popup path, popup-mode
2026-10-29 08:20:35.252 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]: NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
2026-10-29 08:20:35.252 PrivacyBrowser[4969:19394] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:20:35.252 PrivacyBrowser[4969:19394] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:20:35.257 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]: [[BrowserWindowController alloc] initWithBrowsingMode:0 isPopupWindow:YES]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
2026-10-29 08:20:35.257 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:20:35.258 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   1   PrivacyBrowser                      0x000000010242fba4 PBPreprocessException + 48
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:35.653 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   26  PrivacyBrowser                      0x00000001025476d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   27  PrivacyBrowser                      0x000000010253bc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   28  PrivacyBrowser                      0x000000010253fcb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   29  PrivacyBrowser                      0x0000000102543dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   30  PrivacyBrowser                      0x00000001023dcf90 $sIeg_IeyB_TR + 28
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   31  PrivacyBrowser                      0x000000010242fa08 PBCatchException + 36
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   32  PrivacyBrowser                      0x000000010253b990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   33  PrivacyBrowser                      0x000000010253e398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   34  PrivacyBrowser                      0x000000010253a3a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   35  PrivacyBrowser                      0x00000001025512e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   36  PrivacyBrowser                      0x000000010254f3e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   37  PrivacyBrowser                      0x000000010254bdc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   38  PrivacyBrowser                      0x0000000102551e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   39  PrivacyBrowser                      0x000000010260c331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:20:35.654 PrivacyBrowser[4969:19394] SafariWindow[975CA96F]:   4
```

Crash report `PrivacyBrowser-2026-10-29-082037.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:20:37.00 +0000",
    "app_version": "0.1.0",
    "slice_uuid": "4bf1a461-0de2-3603-a83b-42847697e57f",
    "build_version": "1",
    "platform": 1,
    "bundleID": "dev.local.PrivacyBrowser",
    "share_with_app_devs": 0,
    "is_first_party": 0,
    "bug_type": "309",
    "os_version": "macOS 26.6.2 (25G83)",
    "roots_installed": 0,
    "name": "PrivacyBrowser",
    "incident_id": "6A40E002-74DD-4C45-8B3C-185DA4DBDCA8"
  },
  "exception": {
    "codes": "0x0000000000000001, 0x000000018d86b6b4",
    "rawCodes": [
      1,
      6669383348
    ],
    "type": "EXC_BREAKPOINT",
    "signal": "SIGTRAP"
  },
  "termination": {
    "flags": 0,
    "code": 5,
    "namespace": "SIGNAL",
    "indicator": "Trace/BPT trap: 5",
    "byProc": "exc handler",
    "byPid": 4969
  },
  "faultingThread": 0,
  "triggered_frames": [
    "AppKit + 8513204",
    "AppKit + 5413880",
    "AppKit + 5414380",
    "AppKit + 14078072",
    "AppKit + 500440",
    "AppKit + 519184",
    "AppKit + 14036332",
    "AppKit + 500440",
    "AppKit + 519076",
    "AppKit + 14039356",
    "AppKit + 500440",
    "AppKit + 518016",
    "AppKit + 500440",
    "AppKit + 517904",
    "Safari + 138872",
    "AppKit + 1683880",
    "Safari + 137808",
    "AppKit + 1667980",
    "PrivacyBrowser + 1996500",
    "PrivacyBrowser + 1948684",
    "PrivacyBrowser + 1948684",
    "PrivacyBrowser + 1965240",
    "PrivacyBrowser + 1981884",
    "PrivacyBrowser + 511888"
  ]
}
```

## popup-hidden — exited 0

```
PROBE step popup-hidden
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments unset, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments unset, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments unset, app unset, registered unset
PROBE profile store: persistent C1A1CBE8-2501-4036-A1D8-84BAB3CE6D1E
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup-hidden
PROBE   NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
PROBE   RAISED NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x103c60960
PROBE     0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000102a77ba4 PBPreprocessException + 48
PROBE     2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
PROBE     3   CoreFoundation                      0x0000000188d803b4 -[NSObject(NSObject) __retain_OA] + 0
PROBE     4   CoreFoundation                      0x0000000188c2ff68 ___forwarding___ + 1480
PROBE     5   CoreFoundation                      0x0000000188c2f8e0 _CF_forwarding_prep_0 + 96
PROBE     6   Safari                              0x00000001c0b2b1b8 -[BrowserDocument makeWindowControllers] + 168
PROBE     7   Safari                              0x00000001c0cc9f4c -[BrowserDocumentController _createBrowserDocumentWithBrowsingMode:profileIdentifier:configuration:initialSize:options:] + 140
PROBE     8   Safari                              0x00000001c0cc9e40 -[BrowserDocumentController _createBrowserDocumentWithBrowsingMode:profileIdentifier:initialSize:options:] + 248
PROBE     9   Safari                              0x00000001c0cc6494 -[BrowserDocumentController createHiddenEmptyBrowserDocumentWithBrowsingMode:profileIdentifier:jitEnabled:isPopupWindow:restoringFromLastSession:initialSize:] + 64
PROBE     10  Safari                              0x00000001c0d99320 +[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:restoringFromLastSession:] + 108
PROBE     11  Safari                              0x00000001c0d993c4 +[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:] + 20
PROBE     12  PrivacyBrowser                      0x0000000102b87ab8 $s14PrivacyBrowser06SafariB16WindowControllerC011createPopupE033_D5663EB8AEBCFB374BED3A50E441DB28LL_2ofSo8NSObjectCSgAC0G7VariantO_yXlXptF + 460
PROBE     13  PrivacyBrowser                      0x0000000102b878b8 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU_ + 36
PROBE     14  PrivacyBrowser                      0x0000000102a24f90 $sIeg_IeyB_TR + 28
PROBE     15  PrivacyBrowser                      0x0000000102a77a08 PBCatchException + 36
PROBE     16  PrivacyBrowser                      0x0000000102b83990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     17  PrivacyBrowser                      0x0000000102b855fc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 256
PROBE     18  PrivacyBrowser                      0x0000000102b823a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
PROBE     19  PrivacyBrowser                      0x0000000102b992e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
PROBE     20  PrivacyBrowser                      0x0000000102b973e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
PROBE     21  PrivacyBrowser                      0x0000000102b93dc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     22  PrivacyBrowser                      0x0000000102b99e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     23  PrivacyBrowser                      0x0000000102c54331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     24  PrivacyBrowser                      0x0000000102c54319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     25  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
PROBE   creating the controller raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x103c60960; caught, so the attempt ends and the process does not
PROBE   popup path, popup-hidden: giving up — raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x103c60960
PROBE   the profile's store was handed out 3 times during the attempt
PROBE     per-profile store factory asked for C1A1CBE8-2501-4036-A1D8-84BAB3CE6D1E -> handed it persistent C1A1CBE8-2501-4036-A1D8-84BAB3CE6D1E
PROBE     per-profile store factory asked for C1A1CBE8-2501-4036-A1D8-84BAB3CE6D1E -> handed it persistent C1A1CBE8-2501-4036-A1D8-84BAB3CE6D1E
PROBE     websiteDataStore read on WKWebViewConfiguration -> persistent C1A1CBE8-2501-4036-A1D8-84BAB3CE6D1E
PROBE RESULT no window
PROBE activation policy afterwards: 0 (0 = regular, 1 = accessory)
PROBE FALLBACK in-process window: visible=true url=https://example.com/ title=Example Domain
PROBE wrote fallback-window.png (15545 bytes)
PROBE wrote fallback-page.png (76420 bytes)
PROBE step popup-hidden finished
2026-10-29 08:20:44.551 PrivacyBrowser[5190:20101] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:44.552 PrivacyBrowser[5190:20101] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:44.553 PrivacyBrowser[5190:20101] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:44.553 PrivacyBrowser[5190:20101] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:44.640 PrivacyBrowser[5190:20101] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:20:44.641 PrivacyBrowser[5190:20101] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:20:44.642 PrivacyBrowser[5190:20101] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:20:44.967 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:20:44.967 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]: document controller: BrowserDocumentController
2026-10-29 08:20:44.967 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]: popup path, popup-hidden
2026-10-29 08:20:44.968 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]: NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
2026-10-29 08:20:44.968 PrivacyBrowser[5190:20101] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:20:44.968 PrivacyBrowser[5190:20101] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]: RAISED NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x103c60960
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   1   PrivacyBrowser                      0x0000000102a77ba4 PBPreprocessException + 48
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   3   CoreFoundation                      0x0000000188d803b4 -[NSObject(NSObject) __retain_OA] + 0
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   4   CoreFoundation                      0x0000000188c2ff68 ___forwarding___ + 1480
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   5   CoreFoundation                      0x0000000188c2f8e0 _CF_forwarding_prep_0 + 96
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   6   Safari                              0x00000001c0b2b1b8 -[BrowserDocument makeWindowControllers] + 168
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   7   Safari                              0x00000001c0cc9f4c -[BrowserDocumentController _createBrowserDocumentWithBrowsingMode:profileIdentifier:configuration:initialSize:options:] + 140
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   8   Safari                              0x00000001c0cc9e40 -[BrowserDocumentController _createBrowserDocumentWithBrowsingMode:profileIdentifier:initialSize:options:] + 248
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   9   Safari                              0x00000001c0cc6494 -[BrowserDocumentController createHiddenEmptyBrowserDocumentWithBrowsingMode:profileIdentifier:jitEnabled:isPopupWindow:restoringFromLastSession:initialSize:] + 64
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   10  Safari                              0x00000001c0d99320 +[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:restoringFromLastSession:] + 108
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   11  Safari                              0x00000001c0d993c4 +[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:] + 20
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   12  PrivacyBrowser                      0x0000000102b87ab8 $s14PrivacyBrowser06SafariB16WindowControllerC011createPopupE033_D5663EB8AEBCFB374BED3A50E441DB28LL_2ofSo8NSObjectCSgAC0G7VariantO_yXlXptF + 460
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   13  PrivacyBrowser                      0x0000000102b878b8 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU_ + 36
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   14  PrivacyBrowser                      0x0000000102a24f90 $sIeg_IeyB_TR + 28
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   15  PrivacyBrowser                      0x0000000102a77a08 PBCatchException + 36
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   16  PrivacyBrowser                      0x0000000102b83990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   17  PrivacyBrowser                      0x0000000102b855fc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 256
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   18  PrivacyBrowser                      0x0000000102b823a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   19  PrivacyBrowser                      0x0000000102b992e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   20  PrivacyBrowser                      0x0000000102b973e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   21  PrivacyBrowser                      0x0000000102b93dc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   22  PrivacyBrowser                      0x0000000102b99e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   23  PrivacyBrowser                      0x0000000102c54331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:20:45.049 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   24  PrivacyBrowser                      0x0000000102c54319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
2026-10-29 08:20:45.050 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   25  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:20:45.055 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]: creating the controller raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x103c60960; caught, so the attempt ends and the process does not
2026-10-29 08:20:45.055 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]: popup path, popup-hidden: giving up — raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x103c60960
2026-10-29 08:20:45.055 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]: the profile's store was handed out 3 times during the attempt
2026-10-29 08:20:45.055 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   per-profile store factory asked for C1A1CBE8-2501-4036-A1D8-84BAB3CE6D1E -> handed it persistent C1A1CBE8-2501-4036-A1D8-84BAB3CE6D1E
2026-10-29 08:20:45.055 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   per-profile store factory asked for C1A1CBE8-2501-4036-A1D8-84BAB3CE6D1E -> handed it persistent C1A1CBE8-2501-4036-A1D8-84BAB3CE6D1E
2026-10-29 08:20:45.055 PrivacyBrowser[5190:20101] SafariWindow[C1A1CBE8]:   websiteDataStore read on WKWebViewConfiguration -> persistent C1A1CBE8-2501-4036-A1D8-84BAB3CE6D1E
```

## popup:crash-off — killed by SIGTRAP

```
PROBE step popup
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments NO, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments NO, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments NO, app unset, registered unset
PROBE profile store: persistent F9E49702-28D5-4933-8DE9-83E6D3C1F712
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup
PROBE   NSApplicationCrashOnExceptions: reads false; arguments NO, app unset, registered unset
PROBE   [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000100ec7ba4 PBPreprocessException + 48
PROBE     2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
PROBE     3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
PROBE     4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
PROBE     5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
PROBE     6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
PROBE     7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
PROBE     8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
PROBE     9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
PROBE     10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
PROBE     11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
PROBE     12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
PROBE     14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
PROBE     15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
PROBE     17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
PROBE     18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
PROBE     20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
PROBE     22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
PROBE     23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
PROBE     24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
PROBE     25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
PROBE     26  PrivacyBrowser                      0x0000000100fdf6d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
PROBE     27  PrivacyBrowser                      0x0000000100fd3c0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     28  PrivacyBrowser                      0x0000000100fd7cb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     29  PrivacyBrowser                      0x0000000100fdbdbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     30  PrivacyBrowser                      0x0000000100e74f90 $sIeg_IeyB_TR + 28
PROBE     31  PrivacyBrowser                      0x0000000100ec7a08 PBCatchException + 36
PROBE     32  PrivacyBrowser                      0x0000000100fd3990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     33  PrivacyBrowser                      0x0000000100fd6398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
PROBE     34  PrivacyBrowser                      0x0000000100fd23a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
PROBE     35  PrivacyBrowser                      0x0000000100fe92e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
PROBE     36  PrivacyBrowser                      0x0000000100fe73e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
PROBE     37  PrivacyBrowser                      0x0000000100fe3dc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     38  PrivacyBrowser                      0x0000000100fe9e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     39  PrivacyBrowser                      0x00000001010a4331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     40  PrivacyBrowser                      0x00000001010a4319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     41  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:20:50.909 PrivacyBrowser[5400:20734] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:50.909 PrivacyBrowser[5400:20734] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:50.909 PrivacyBrowser[5400:20734] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:50.909 PrivacyBrowser[5400:20734] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:50.994 PrivacyBrowser[5400:20734] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:20:50.995 PrivacyBrowser[5400:20734] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:20:50.995 PrivacyBrowser[5400:20734] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:20:51.198 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:20:51.198 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]: document controller: BrowserDocumentController
2026-10-29 08:20:51.198 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]: popup path, popup
2026-10-29 08:20:51.198 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]: NSApplicationCrashOnExceptions: reads false; arguments NO, app unset, registered unset
2026-10-29 08:20:51.199 PrivacyBrowser[5400:20734] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:20:51.199 PrivacyBrowser[5400:20734] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:20:51.216 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]: [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
2026-10-29 08:20:51.216 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:20:51.216 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   1   PrivacyBrowser                      0x0000000100ec7ba4 PBPreprocessException + 48
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   26  PrivacyBrowser                      0x0000000100fdf6d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   27  PrivacyBrowser                      0x0000000100fd3c0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   28  PrivacyBrowser                      0x0000000100fd7cb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   29  PrivacyBrowser                      0x0000000100fdbdbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   30  PrivacyBrowser                      0x0000000100e74f90 $sIeg_IeyB_TR + 28
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   31  PrivacyBrowser                      0x0000000100ec7a08 PBCatchException + 36
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   32  PrivacyBrowser                      0x0000000100fd3990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   33  PrivacyBrowser                      0x0000000100fd6398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   34  PrivacyBrowser                      0x0000000100fd23a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   35  PrivacyBrowser                      0x0000000100fe92e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   36  PrivacyBrowser                      0x0000000100fe73e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   37  PrivacyBrowser                      0x0000000100fe3dc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   38  PrivacyBrowser                      0x0000000100fe9e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   39  PrivacyBrowser                      0x00000001010a4331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:20:51.537 PrivacyBrowser[5400:20734] SafariWindow[F9E49702]:   40  PrivacyBrowser                      0x00000001010a4319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5Ne
```

Crash report `PrivacyBrowser-2026-10-29-082052.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:20:52.00 +0000",
    "app_version": "0.1.0",
    "slice_uuid": "4bf1a461-0de2-3603-a83b-42847697e57f",
    "build_version": "1",
    "platform": 1,
    "bundleID": "dev.local.PrivacyBrowser",
    "share_with_app_devs": 0,
    "is_first_party": 0,
    "bug_type": "309",
    "os_version": "macOS 26.6.2 (25G83)",
    "roots_installed": 0,
    "name": "PrivacyBrowser",
    "incident_id": "7495371D-9F09-4234-A84A-165232F53B22"
  },
  "exception": {
    "codes": "0x0000000000000001, 0x000000018d86b6b4",
    "rawCodes": [
      1,
      6669383348
    ],
    "type": "EXC_BREAKPOINT",
    "signal": "SIGTRAP"
  },
  "termination": {
    "flags": 0,
    "code": 5,
    "namespace": "SIGNAL",
    "indicator": "Trace/BPT trap: 5",
    "byProc": "exc handler",
    "byPid": 5400
  },
  "faultingThread": 0,
  "triggered_frames": [
    "AppKit + 8513204",
    "AppKit + 5413880",
    "AppKit + 5414380",
    "AppKit + 14078072",
    "AppKit + 500440",
    "AppKit + 519184",
    "AppKit + 14036332",
    "AppKit + 500440",
    "AppKit + 519076",
    "AppKit + 14039356",
    "AppKit + 500440",
    "AppKit + 518016",
    "AppKit + 500440",
    "AppKit + 517904",
    "Safari + 138872",
    "AppKit + 1683880",
    "Safari + 137808",
    "AppKit + 1667980",
    "PrivacyBrowser + 1996500",
    "PrivacyBrowser + 1948684",
    "PrivacyBrowser + 1948684",
    "PrivacyBrowser + 1965240",
    "PrivacyBrowser + 1981884",
    "PrivacyBrowser + 511888"
  ]
}
```

## window:chrome — killed by SIGTRAP

```
PROBE step window
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments NO, app 1, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments NO, app 1, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments NO, app 1, registered unset
PROBE profile store: persistent 1CD82F31-3785-4504-836E-D9D54D9AA478
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup
PROBE   NSApplicationCrashOnExceptions: reads false; arguments NO, app 1, registered unset
PROBE   [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000104613ba4 PBPreprocessException + 48
PROBE     2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
PROBE     3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
PROBE     4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
PROBE     5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
PROBE     6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
PROBE     7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
PROBE     8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
PROBE     9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
PROBE     10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
PROBE     11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
PROBE     12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
PROBE     14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
PROBE     15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
PROBE     17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
PROBE     18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
PROBE     20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
PROBE     21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
PROBE     22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
PROBE     23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
PROBE     24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
PROBE     25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
PROBE     26  PrivacyBrowser                      0x000000010472b6d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
PROBE     27  PrivacyBrowser                      0x000000010471fc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     28  PrivacyBrowser                      0x0000000104723cb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     29  PrivacyBrowser                      0x0000000104727dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     30  PrivacyBrowser                      0x00000001045c0f90 $sIeg_IeyB_TR + 28
PROBE     31  PrivacyBrowser                      0x0000000104613a08 PBCatchException + 36
PROBE     32  PrivacyBrowser                      0x000000010471f990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     33  PrivacyBrowser                      0x0000000104722398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
PROBE     34  PrivacyBrowser                      0x000000010471e3a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
PROBE     35  PrivacyBrowser                      0x000000010471c5e8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 540
PROBE     36  PrivacyBrowser                      0x0000000104730fb0 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZ04$s14a9Browser20cde17O10windowStep33_9ijklmno11LLyyYaFZSo8p10CSgAA0cB16qr6C_So18stU24C10Foundation3URLVtXEfU_Tf1cn_nTY0_ + 1092
PROBE     37  PrivacyBrowser                      0x000000010472ff49 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ5_ + 1
PROBE     38  PrivacyBrowser                      0x0000000104735e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     39  PrivacyBrowser                      0x00000001047f0331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     40  PrivacyBrowser                      0x00000001047f0319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     41  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:21:00.675 PrivacyBrowser[5568:21338] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:00.676 PrivacyBrowser[5568:21338] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:00.676 PrivacyBrowser[5568:21338] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:00.676 PrivacyBrowser[5568:21338] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:00.748 PrivacyBrowser[5568:21338] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:21:00.750 PrivacyBrowser[5568:21338] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:21:00.750 PrivacyBrowser[5568:21338] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:21:01.002 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:21:01.002 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]: document controller: BrowserDocumentController
2026-10-29 08:21:01.002 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]: popup path, popup
2026-10-29 08:21:01.003 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]: NSApplicationCrashOnExceptions: reads false; arguments NO, app 1, registered unset
2026-10-29 08:21:01.003 PrivacyBrowser[5568:21338] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:21:01.003 PrivacyBrowser[5568:21338] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:21:01.010 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]: [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
2026-10-29 08:21:01.011 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:21:01.011 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   1   PrivacyBrowser                      0x0000000104613ba4 PBPreprocessException + 48
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   26  PrivacyBrowser                      0x000000010472b6d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   27  PrivacyBrowser                      0x000000010471fc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   28  PrivacyBrowser                      0x0000000104723cb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   29  PrivacyBrowser                      0x0000000104727dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   30  PrivacyBrowser                      0x00000001045c0f90 $sIeg_IeyB_TR + 28
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   31  PrivacyBrowser                      0x0000000104613a08 PBCatchException + 36
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   32  PrivacyBrowser                      0x000000010471f990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   33  PrivacyBrowser                      0x0000000104722398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   34  PrivacyBrowser                      0x000000010471e3a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   35  PrivacyBrowser                      0x000000010471c5e8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 540
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   36  PrivacyBrowser                      0x0000000104730fb0 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZ04$s14a9Browser20cde17O10windowStep33_9ijklmno11LLyyYaFZSo8p10CSgAA0cB16qr6C_So18stU24C10Foundation3URLVtXEfU_Tf1cn_nTY0_ + 1092
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   37  PrivacyBrowser                      0x000000010472ff49 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ5_ + 1
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   38  PrivacyBrowser                      0x0000000104735e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   39  PrivacyBrowser                      0x00000001047f0331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:21:01.358 PrivacyBrowser[5568:21338] SafariWindow[1CD82F31]:   40  PrivacyBrowser      
```

Crash report `PrivacyBrowser-2026-10-29-082102.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:21:02.00 +0000",
    "app_version": "0.1.0",
    "slice_uuid": "4bf1a461-0de2-3603-a83b-42847697e57f",
    "build_version": "1",
    "platform": 1,
    "bundleID": "dev.local.PrivacyBrowser",
    "share_with_app_devs": 0,
    "is_first_party": 0,
    "bug_type": "309",
    "os_version": "macOS 26.6.2 (25G83)",
    "roots_installed": 0,
    "name": "PrivacyBrowser",
    "incident_id": "DD9233E0-8746-42D9-9864-F73BE765FFD7"
  },
  "exception": {
    "codes": "0x0000000000000001, 0x000000018d86b6b4",
    "rawCodes": [
      1,
      6669383348
    ],
    "type": "EXC_BREAKPOINT",
    "signal": "SIGTRAP"
  },
  "termination": {
    "flags": 0,
    "code": 5,
    "namespace": "SIGNAL",
    "indicator": "Trace/BPT trap: 5",
    "byProc": "exc handler",
    "byPid": 5568
  },
  "faultingThread": 0,
  "triggered_frames": [
    "AppKit + 8513204",
    "AppKit + 5413880",
    "AppKit + 5414380",
    "AppKit + 14078072",
    "AppKit + 500440",
    "AppKit + 519184",
    "AppKit + 14036332",
    "AppKit + 500440",
    "AppKit + 519076",
    "AppKit + 14039356",
    "AppKit + 500440",
    "AppKit + 518016",
    "AppKit + 500440",
    "AppKit + 517904",
    "Safari + 138872",
    "AppKit + 1683880",
    "Safari + 137808",
    "AppKit + 1667980",
    "PrivacyBrowser + 1996500",
    "PrivacyBrowser + 1948684",
    "PrivacyBrowser + 1948684",
    "PrivacyBrowser + 1965240",
    "PrivacyBrowser + 1981884",
    "PrivacyBrowser + 511888"
  ]
}
```
