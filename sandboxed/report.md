# Framework window probe

macOS 26.6.2 (25G83), arm64, SIP: System Integrity Protection status: disabled.
built with SDK 26.5, Xcode 26.6 Build version 17F113
app: build/sandboxed/PrivacyBrowser.app

| step | outcome | seconds | why |
|---|---|---|---|
| image | exited 0 | 0.7 |  |
| classes | exited 0 | 0.2 |  |
| selectors | exited 0 | 1.1 |  |
| appcontroller | exited 0 | 0.2 |  |
| windowcontroller | exited 0 | 0.2 |  |
| documentcontroller | exited 0 | 0.1 |  |
| documentcontroller-create | exited 0 | 0.5 |  |
| webconfig | exited 0 | 0.1 |  |
| shared | exited 0 | 0.3 |  |
| create-direct | killed by SIGSEGV | 0.4 | SIGNAL 11 / Segmentation fault: 11 / EXC_BAD_ACCESS SIGSEGV |
| create | killed by SIGTRAP | 1.1 | SIGNAL 5 / Trace/BPT trap: 5 / EXC_BREAKPOINT SIGTRAP |
| create-bootstrap | killed by SIGTRAP | 0.7 | SIGNAL 5 / Trace/BPT trap: 5 / EXC_BREAKPOINT SIGTRAP |
| window | killed by SIGTRAP | 1.2 | SIGNAL 5 / Trace/BPT trap: 5 / EXC_BREAKPOINT SIGTRAP |
| popupfield | exited 0 | 0.4 |  |
| popup | killed by SIGTRAP | 1.1 | SIGNAL 5 / Trace/BPT trap: 5 / EXC_BREAKPOINT SIGTRAP |
| popup-nofield | killed by SIGTRAP | 0.7 | SIGNAL 5 / Trace/BPT trap: 5 / EXC_BREAKPOINT SIGTRAP |
| popup-mode | killed by SIGTRAP | 1.6 | SIGNAL 5 / Trace/BPT trap: 5 / EXC_BREAKPOINT SIGTRAP |
| popup-hidden | exited 0 | 4.1 | raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x105cef340; no window |
| popup:crash-off | killed by SIGTRAP | 1.6 | SIGNAL 5 / Trace/BPT trap: 5 / EXC_BREAKPOINT SIGTRAP |
| window:chrome | killed by SIGTRAP | 0.5 | SIGNAL 5 / Trace/BPT trap: 5 / EXC_BREAKPOINT SIGTRAP |

## image — exited 0

```
PROBE step image
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: true
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
2026-10-29 08:21:22.270 PrivacyBrowser[6138:23029] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:22.271 PrivacyBrowser[6138:23029] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:22.271 PrivacyBrowser[6138:23029] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:22.271 PrivacyBrowser[6138:23029] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:22.358 PrivacyBrowser[6138:23029] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## classes — exited 0

```
PROBE step classes
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: true
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
2026-10-29 08:21:22.466 PrivacyBrowser[6168:23120] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:22.467 PrivacyBrowser[6168:23120] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:22.467 PrivacyBrowser[6168:23120] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:22.468 PrivacyBrowser[6168:23120] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:22.494 PrivacyBrowser[6168:23120] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## selectors — exited 0

```
PROBE step selectors
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: true
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
2026-10-29 08:21:22.621 PrivacyBrowser[6195:23182] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:22.623 PrivacyBrowser[6195:23182] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:22.623 PrivacyBrowser[6195:23182] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:22.623 PrivacyBrowser[6195:23182] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:22.638 PrivacyBrowser[6195:23182] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## appcontroller — exited 0

```
PROBE step appcontroller
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: true
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
2026-10-29 08:21:23.785 PrivacyBrowser[6375:23582] SafariLoader: classNames -> nil (framework image not in the loaded image list)
2026-10-29 08:21:23.786 PrivacyBrowser[6375:23582] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:23.786 PrivacyBrowser[6375:23582] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:23.786 PrivacyBrowser[6375:23582] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:23.787 PrivacyBrowser[6375:23582] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:23.814 PrivacyBrowser[6375:23582] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## windowcontroller — exited 0

```
PROBE step windowcontroller
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: true
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
2026-10-29 08:21:24.013 PrivacyBrowser[6404:23647] SafariLoader: classNames -> nil (framework image not in the loaded image list)
2026-10-29 08:21:24.014 PrivacyBrowser[6404:23647] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:24.014 PrivacyBrowser[6404:23647] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:24.014 PrivacyBrowser[6404:23647] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:24.014 PrivacyBrowser[6404:23647] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:24.029 PrivacyBrowser[6404:23647] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## documentcontroller — exited 0

```
PROBE step documentcontroller
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: true
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
2026-10-29 08:21:24.245 PrivacyBrowser[6438:23721] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:24.247 PrivacyBrowser[6438:23721] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:24.247 PrivacyBrowser[6438:23721] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:24.247 PrivacyBrowser[6438:23721] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:24.267 PrivacyBrowser[6438:23721] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## documentcontroller-create — exited 0

```
PROBE step documentcontroller-create
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: true
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads true; arguments YES, app 1, registered unset
PROBE chain: BrowserDocumentController <- NSDocumentController <- NSObject
PROBE declares -init: true, -_commonInit: true
PROBE declares +sharedDocumentController: true
PROBE a document controller exists before we ask: this step is about to find out
PROBE +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> nil
PROBE NSDocumentController.shared is NSDocumentController
PROBE step documentcontroller-create finished
2026-10-29 08:21:24.783 PrivacyBrowser[6449:23748] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:24.785 PrivacyBrowser[6449:23748] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:24.785 PrivacyBrowser[6449:23748] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:24.785 PrivacyBrowser[6449:23748] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:24.806 PrivacyBrowser[6449:23748] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## webconfig — exited 0

```
PROBE step webconfig
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: true
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE configuration factories: _webViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:relatedWebView:groupIdentifier:preferences:userContentController:jitEnabled:preferencesManager:, _webViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:relatedWebView:groupIdentifier:preferences:userContentController:webExtensionsController:jitEnabled:preferencesManager:, automationPreferencesWithConfiguration:, contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:, contentWebViewConfigurationForBrowsingMode:profileIdentifier:jitEnabled:, readerWebViewConfigurationForBrowsingMode:profileIdentifier:relatedWebView:, webExtensionWebViewConfigurationForExtension:, webExtensionWebViewConfigurationForExtensionsController:
PROBE calling +[WebKitPreferencesManager contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:] for profile BB80CC93-0ADA-4096-8313-0F5AB32BAD5E …
PROBE   contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier: -> WKWebViewConfiguration
PROBE   websiteDataStore: persistent BB80CC93-0ADA-4096-8313-0F5AB32BAD5E
PROBE with the profile's store bound: contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier: -> WKWebViewConfiguration
PROBE   per-profile store factory asked for B71F6743-07A1-4383-8651-5C0A2FDEC72E -> handed it non-persistent
PROBE   websiteDataStore is the bound one: true
PROBE step webconfig finished
2026-10-29 08:21:24.862 PrivacyBrowser[6466:23827] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:24.862 PrivacyBrowser[6466:23827] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:24.862 PrivacyBrowser[6466:23827] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:24.862 PrivacyBrowser[6466:23827] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:24.885 PrivacyBrowser[6466:23827] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:21:24.956 PrivacyBrowser[6466:23827] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:21:24.956 PrivacyBrowser[6466:23827] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
```

## shared — exited 0

```
PROBE step shared
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: true
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
2026-10-29 08:21:25.017 PrivacyBrowser[6470:23862] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:25.017 PrivacyBrowser[6470:23862] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:25.018 PrivacyBrowser[6470:23862] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:25.018 PrivacyBrowser[6470:23862] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:25.038 PrivacyBrowser[6470:23862] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:21:25.040 PrivacyBrowser[6470:23862] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:21:25.040 PrivacyBrowser[6470:23862] SafariWindow: +sharedDocumentController is now BrowserDocumentController
```

## create-direct — killed by SIGSEGV

```
PROBE step create-direct
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: true
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
2026-10-29 08:21:25.281 PrivacyBrowser[6479:23897] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:25.282 PrivacyBrowser[6479:23897] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:25.283 PrivacyBrowser[6479:23897] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:25.284 PrivacyBrowser[6479:23897] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:25.301 PrivacyBrowser[6479:23897] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:21:25.304 PrivacyBrowser[6479:23897] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:21:25.304 PrivacyBrowser[6479:23897] SafariWindow: +sharedDocumentController is now BrowserDocumentController
```

Crash report `PrivacyBrowser-2026-10-29-082127.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:21:27.00 +0000",
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
    "incident_id": "6546A787-1BB7-4919-96FB-ADD0219CCD07"
  },
  "exception": {
    "codes": "0x0000000000000001, 0x000079324589b878",
    "rawCodes": [
      1,
      133256821979256
    ],
    "type": "EXC_BAD_ACCESS",
    "signal": "SIGSEGV",
    "subtype": "KERN_INVALID_ADDRESS at 0x000079324589b878"
  },
  "termination": {
    "flags": 0,
    "code": 11,
    "namespace": "SIGNAL",
    "indicator": "Segmentation fault: 11",
    "byProc": "exc handler",
    "byPid": 6479
  },
  "vmRegionInfo": "0x79324589b878 is not in any region.  \n      REGION TYPE                    START - END         [ VSIZE] PRT/MAX SHRMOD  REGION DETAIL\n      UNUSED SPACE AT START\n--->  \n      UNUSED SPACE AT END",
  "faultingThread": 3,
  "triggered_frames": [
    "libobjc.A.dylib + 31004",
    "libobjc.A.dylib + 79940",
    "Foundation + 142428",
    "Foundation + 142264",
    "WebBookmarks + 66284",
    "libdispatch.dylib + 6696",
    "libdispatch.dylib + 111792",
    "libdispatch.dylib + 41008",
    "libdispatch.dylib + 43876",
    "libdispatch.dylib + 85556",
    "libdispatch.dylib + 83764",
    "libsystem_pthread.dylib + 11968",
    "libsystem_pthread.dylib + 7184"
  ]
}
```

## create — killed by SIGTRAP

```
PROBE step create
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: true
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
PROBE     1   PrivacyBrowser                      0x0000000100163ba4 PBPreprocessException + 48
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
PROBE     26  PrivacyBrowser                      0x000000010027b6d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
PROBE     27  PrivacyBrowser                      0x000000010026fc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     28  PrivacyBrowser                      0x0000000100273cb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     29  PrivacyBrowser                      0x0000000100277dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     30  PrivacyBrowser                      0x0000000100110f90 $sIeg_IeyB_TR + 28
PROBE     31  PrivacyBrowser                      0x0000000100163a08 PBCatchException + 36
PROBE     32  PrivacyBrowser                      0x000000010026f990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     33  PrivacyBrowser                      0x000000010026c9ac $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1504
PROBE     34  PrivacyBrowser                      0x0000000100280740 $s14PrivacyBrowser20SafariFrameworkProbeO10createStep33_9F0153DCAF2CE7EC9F01CEB735D44942LL9bootstrapySb_tFZ + 468
PROBE     35  PrivacyBrowser                      0x000000010027fc84 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TY0_ + 500
PROBE     36  PrivacyBrowser                      0x0000000100285e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     37  PrivacyBrowser                      0x0000000100340331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     38  PrivacyBrowser                      0x0000000100340319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     39  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:21:35.249 PrivacyBrowser[6623:24375] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:35.250 PrivacyBrowser[6623:24375] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:35.250 PrivacyBrowser[6623:24375] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:35.250 PrivacyBrowser[6623:24375] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:35.336 PrivacyBrowser[6623:24375] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:21:35.340 PrivacyBrowser[6623:24375] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:21:35.340 PrivacyBrowser[6623:24375] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:21:35.660 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:21:35.668 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]: document controller: BrowserDocumentController
2026-10-29 08:21:35.669 PrivacyBrowser[6623:24375] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:21:35.669 PrivacyBrowser[6623:24375] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:21:35.671 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]: BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
2026-10-29 08:21:35.674 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]: [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
2026-10-29 08:21:35.674 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]: window controller: BrowserWindowController
2026-10-29 08:21:36.238 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:21:36.238 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:21:36.238 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   1   PrivacyBrowser                      0x0000000100163ba4 PBPreprocessException + 48
2026-10-29 08:21:36.238 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:21:36.238 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:21:36.238 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:21:36.238 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
2026-10-29 08:21:36.238 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
2026-10-29 08:21:36.238 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
2026-10-29 08:21:36.238 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   26  PrivacyBrowser                      0x000000010027b6d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   27  PrivacyBrowser                      0x000000010026fc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   28  PrivacyBrowser                      0x0000000100273cb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   29  PrivacyBrowser                      0x0000000100277dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   30  PrivacyBrowser                      0x0000000100110f90 $sIeg_IeyB_TR + 28
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   31  PrivacyBrowser                      0x0000000100163a08 PBCatchException + 36
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   32  PrivacyBrowser                      0x000000010026f990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   33  PrivacyBrowser                      0x000000010026c9ac $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1504
2026-10-29 08:21:36.239 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   34  PrivacyBrowser                      0x0000000100280740 $s14PrivacyBrowser20SafariFrameworkProbeO10createStep33_9F0153DCAF2CE7EC9F01CEB735D44942LL9bootstrapySb_tFZ + 468
2026-10-29 08:21:36.240 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   35  PrivacyBrowser                      0x000000010027fc84 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TY0_ + 500
2026-10-29 08:21:36.240 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   36  PrivacyBrowser                      0x0000000100285e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:21:36.240 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   37  PrivacyBrowser                      0x0000000100340331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:21:36.240 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   38  PrivacyBrowser                      0x0000000100340319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
2026-10-29 08:21:36.240 PrivacyBrowser[6623:24375] SafariWindow[F9A8F1DC]:   39  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
```

Crash report `PrivacyBrowser-2026-10-29-082137.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:21:37.00 +0000",
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
    "incident_id": "897D1CC3-9A75-4133-B458-4DA3FE4A4895"
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
    "byPid": 6623
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
PROBE sandboxed: true
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
PROBE     1   PrivacyBrowser                      0x0000000102b73ba4 PBPreprocessException + 48
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
PROBE     26  PrivacyBrowser                      0x0000000102c8b6d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
PROBE     27  PrivacyBrowser                      0x0000000102c7fc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     28  PrivacyBrowser                      0x0000000102c83cb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     29  PrivacyBrowser                      0x0000000102c87dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     30  PrivacyBrowser                      0x0000000102b20f90 $sIeg_IeyB_TR + 28
PROBE     31  PrivacyBrowser                      0x0000000102b73a08 PBCatchException + 36
PROBE     32  PrivacyBrowser                      0x0000000102c7f990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     33  PrivacyBrowser                      0x0000000102c7c9ac $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1504
PROBE     34  PrivacyBrowser                      0x0000000102c90740 $s14PrivacyBrowser20SafariFrameworkProbeO10createStep33_9F0153DCAF2CE7EC9F01CEB735D44942LL9bootstrapySb_tFZ + 468
PROBE     35  PrivacyBrowser                      0x0000000102c8fc84 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TY0_ + 500
PROBE     36  PrivacyBrowser                      0x0000000102c95e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     37  PrivacyBrowser                      0x0000000102d50331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     38  PrivacyBrowser                      0x0000000102d50319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     39  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:21:45.605 PrivacyBrowser[6749:24963] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:45.606 PrivacyBrowser[6749:24963] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:45.606 PrivacyBrowser[6749:24963] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:45.606 PrivacyBrowser[6749:24963] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:45.658 PrivacyBrowser[6749:24963] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:21:45.659 PrivacyBrowser[6749:24963] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:21:45.659 PrivacyBrowser[6749:24963] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:21:45.848 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:21:45.848 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]: document controller: BrowserDocumentController
2026-10-29 08:21:45.848 PrivacyBrowser[6749:24963] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:21:45.848 PrivacyBrowser[6749:24963] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:21:45.850 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]: BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
2026-10-29 08:21:45.852 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]: [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
2026-10-29 08:21:45.852 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]: window controller: BrowserWindowController
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   1   PrivacyBrowser                      0x0000000102b73ba4 PBPreprocessException + 48
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   26  PrivacyBrowser                      0x0000000102c8b6d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   27  PrivacyBrowser                      0x0000000102c7fc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   28  PrivacyBrowser                      0x0000000102c83cb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   29  PrivacyBrowser                      0x0000000102c87dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   30  PrivacyBrowser                      0x0000000102b20f90 $sIeg_IeyB_TR + 28
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   31  PrivacyBrowser                      0x0000000102b73a08 PBCatchException + 36
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   32  PrivacyBrowser                      0x0000000102c7f990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   33  PrivacyBrowser                      0x0000000102c7c9ac $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1504
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   34  PrivacyBrowser                      0x0000000102c90740 $s14PrivacyBrowser20SafariFrameworkProbeO10createStep33_9F0153DCAF2CE7EC9F01CEB735D44942LL9bootstrapySb_tFZ + 468
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   35  PrivacyBrowser                      0x0000000102c8fc84 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TY0_ + 500
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   36  PrivacyBrowser                      0x0000000102c95e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   37  PrivacyBrowser                      0x0000000102d50331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   38  PrivacyBrowser                      0x0000000102d50319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
2026-10-29 08:21:46.194 PrivacyBrowser[6749:24963] SafariWindow[2BD043D5]:   39  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
```

Crash report `PrivacyBrowser-2026-10-29-082147.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:21:47.00 +0000",
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
    "incident_id": "FDD43825-CE42-4EF7-BAE5-812924CF95E8"
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
    "byPid": 6749
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

## window — killed by SIGTRAP

```
PROBE step window
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: true
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads true; arguments YES, app 1, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads true; arguments YES, app 1, registered unset
PROBE profile store: persistent B656959E-BB64-40E0-A3AC-C14BB33772B6
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
PROBE   [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
PROBE   window controller: BrowserWindowController
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000104ecbba4 PBPreprocessException + 48
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
PROBE     26  PrivacyBrowser                      0x0000000104fe36d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
PROBE     27  PrivacyBrowser                      0x0000000104fd7c0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     28  PrivacyBrowser                      0x0000000104fdbcb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     29  PrivacyBrowser                      0x0000000104fdfdbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     30  PrivacyBrowser                      0x0000000104e78f90 $sIeg_IeyB_TR + 28
PROBE     31  PrivacyBrowser                      0x0000000104ecba08 PBCatchException + 36
PROBE     32  PrivacyBrowser                      0x0000000104fd7990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     33  PrivacyBrowser                      0x0000000104fd49ac $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1504
PROBE     34  PrivacyBrowser                      0x0000000104fe8fb0 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZ04$s14a9Browser20cde17O10windowStep33_9ijklmno11LLyyYaFZSo8p10CSgAA0cB16qr6C_So18stU24C10Foundation3URLVtXEfU_Tf1cn_nTY0_ + 1092
PROBE     35  PrivacyBrowser                      0x0000000104fe7f49 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ5_ + 1
PROBE     36  PrivacyBrowser                      0x0000000104fede5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     37  PrivacyBrowser                      0x00000001050a8331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     38  PrivacyBrowser                      0x00000001050a8319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     39  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:21:56.034 PrivacyBrowser[6954:25650] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:56.035 PrivacyBrowser[6954:25650] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:21:56.035 PrivacyBrowser[6954:25650] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:56.035 PrivacyBrowser[6954:25650] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:21:56.119 PrivacyBrowser[6954:25650] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:21:56.122 PrivacyBrowser[6954:25650] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:21:56.122 PrivacyBrowser[6954:25650] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:21:56.521 PrivacyBrowser[6954:25650] SafariWindow[B656959E]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:21:56.521 PrivacyBrowser[6954:25650] SafariWindow[B656959E]: document controller: BrowserDocumentController
2026-10-29 08:21:56.522 PrivacyBrowser[6954:25650] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:21:56.522 PrivacyBrowser[6954:25650] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:21:56.523 PrivacyBrowser[6954:25650] SafariWindow[B656959E]: BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
2026-10-29 08:21:56.528 PrivacyBrowser[6954:25650] SafariWindow[B656959E]: [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
2026-10-29 08:21:56.528 PrivacyBrowser[6954:25650] SafariWindow[B656959E]: window controller: BrowserWindowController
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   1   PrivacyBrowser                      0x0000000104ecbba4 PBPreprocessException + 48
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:21:57.107 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   26  PrivacyBrowser                      0x0000000104fe36d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   27  PrivacyBrowser                      0x0000000104fd7c0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   28  PrivacyBrowser                      0x0000000104fdbcb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   29  PrivacyBrowser                      0x0000000104fdfdbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   30  PrivacyBrowser                      0x0000000104e78f90 $sIeg_IeyB_TR + 28
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   31  PrivacyBrowser                      0x0000000104ecba08 PBCatchException + 36
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   32  PrivacyBrowser                      0x0000000104fd7990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   33  PrivacyBrowser                      0x0000000104fd49ac $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1504
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   34  PrivacyBrowser                      0x0000000104fe8fb0 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZ04$s14a9Browser20cde17O10windowStep33_9ijklmno11LLyyYaFZSo8p10CSgAA0cB16qr6C_So18stU24C10Foundation3URLVtXEfU_Tf1cn_nTY0_ + 1092
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   35  PrivacyBrowser                      0x0000000104fe7f49 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ5_ + 1
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   36  PrivacyBrowser                      0x0000000104fede5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   37  PrivacyBrowser                      0x00000001050a8331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   38  PrivacyBrowser                      0x00000001050a8319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
2026-10-29 08:21:57.108 PrivacyBrowser[6954:25650] SafariWindow[B656959E]:   39  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
```

Crash report `PrivacyBrowser-2026-10-29-082158.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:21:58.00 +0000",
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
    "incident_id": "3F9EA3D9-FD50-4D3F-BE59-EA2EE88C9482"
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
    "byPid": 6954
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
PROBE sandboxed: true
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
2026-10-29 08:22:07.739 PrivacyBrowser[7184:26560] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:22:07.740 PrivacyBrowser[7184:26560] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:22:07.740 PrivacyBrowser[7184:26560] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:22:07.740 PrivacyBrowser[7184:26560] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:22:07.828 PrivacyBrowser[7184:26560] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## popup — killed by SIGTRAP

```
PROBE step popup
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: true
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments unset, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments unset, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments unset, app unset, registered unset
PROBE profile store: persistent 86D2B341-AB97-466E-928B-AE3C696F4817
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup
PROBE   NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
PROBE   [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x00000001005cbba4 PBPreprocessException + 48
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
PROBE     26  PrivacyBrowser                      0x00000001006e36d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
PROBE     27  PrivacyBrowser                      0x00000001006d7c0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     28  PrivacyBrowser                      0x00000001006dbcb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     29  PrivacyBrowser                      0x00000001006dfdbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     30  PrivacyBrowser                      0x0000000100578f90 $sIeg_IeyB_TR + 28
PROBE     31  PrivacyBrowser                      0x00000001005cba08 PBCatchException + 36
PROBE     32  PrivacyBrowser                      0x00000001006d7990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     33  PrivacyBrowser                      0x00000001006da398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
PROBE     34  PrivacyBrowser                      0x00000001006d63a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
PROBE     35  PrivacyBrowser                      0x00000001006ed2e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
PROBE     36  PrivacyBrowser                      0x00000001006eb3e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
PROBE     37  PrivacyBrowser                      0x00000001006e7dc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     38  PrivacyBrowser                      0x00000001006ede5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     39  PrivacyBrowser                      0x00000001007a8331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     40  PrivacyBrowser                      0x00000001007a8319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     41  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:22:08.070 PrivacyBrowser[7186:26567] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:22:08.071 PrivacyBrowser[7186:26567] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:22:08.071 PrivacyBrowser[7186:26567] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:22:08.071 PrivacyBrowser[7186:26567] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:22:08.084 PrivacyBrowser[7186:26567] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:22:08.084 PrivacyBrowser[7186:26567] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:22:08.085 PrivacyBrowser[7186:26567] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:22:08.496 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:22:08.498 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]: document controller: BrowserDocumentController
2026-10-29 08:22:08.498 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]: popup path, popup
2026-10-29 08:22:08.498 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]: NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
2026-10-29 08:22:08.498 PrivacyBrowser[7186:26567] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:22:08.498 PrivacyBrowser[7186:26567] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:22:08.523 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]: [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
2026-10-29 08:22:08.523 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:22:08.523 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:22:09.064 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:22:09.064 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:22:09.064 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   1   PrivacyBrowser                      0x00000001005cbba4 PBPreprocessException + 48
2026-10-29 08:22:09.064 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:22:09.064 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:22:09.064 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:22:09.064 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
2026-10-29 08:22:09.064 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
2026-10-29 08:22:09.064 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
2026-10-29 08:22:09.064 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   26  PrivacyBrowser                      0x00000001006e36d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   27  PrivacyBrowser                      0x00000001006d7c0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   28  PrivacyBrowser                      0x00000001006dbcb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   29  PrivacyBrowser                      0x00000001006dfdbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   30  PrivacyBrowser                      0x0000000100578f90 $sIeg_IeyB_TR + 28
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   31  PrivacyBrowser                      0x00000001005cba08 PBCatchException + 36
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   32  PrivacyBrowser                      0x00000001006d7990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   33  PrivacyBrowser                      0x00000001006da398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   34  PrivacyBrowser                      0x00000001006d63a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   35  PrivacyBrowser                      0x00000001006ed2e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   36  PrivacyBrowser                      0x00000001006eb3e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   37  PrivacyBrowser                      0x00000001006e7dc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   38  PrivacyBrowser                      0x00000001006ede5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   39  PrivacyBrowser                      0x00000001007a8331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:22:09.065 PrivacyBrowser[7186:26567] SafariWindow[86D2B341]:   40  PrivacyBrowser                      0x00000001007a8319 $sxIeAgHr_xs5Error_pIegHrzo_s8
```

Crash report `PrivacyBrowser-2026-10-29-082210.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:22:10.00 +0000",
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
    "incident_id": "2388DFB6-0E3E-4629-90E9-C5ED3898D972"
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
    "byPid": 7186
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
PROBE sandboxed: true
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments unset, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments unset, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments unset, app unset, registered unset
PROBE profile store: persistent D55C1378-F2A3-4193-A855-F05E9D62F155
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
PROBE     1   PrivacyBrowser                      0x0000000102d8fba4 PBPreprocessException + 48
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
PROBE     26  PrivacyBrowser                      0x0000000102ea76d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
PROBE     27  PrivacyBrowser                      0x0000000102e9bc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     28  PrivacyBrowser                      0x0000000102e9fcb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     29  PrivacyBrowser                      0x0000000102ea3dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     30  PrivacyBrowser                      0x0000000102d3cf90 $sIeg_IeyB_TR + 28
PROBE     31  PrivacyBrowser                      0x0000000102d8fa08 PBCatchException + 36
PROBE     32  PrivacyBrowser                      0x0000000102e9b990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     33  PrivacyBrowser                      0x0000000102e9e398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
PROBE     34  PrivacyBrowser                      0x0000000102e9a3a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
PROBE     35  PrivacyBrowser                      0x0000000102eb12e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
PROBE     36  PrivacyBrowser                      0x0000000102eaf3e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
PROBE     37  PrivacyBrowser                      0x0000000102eabdc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     38  PrivacyBrowser                      0x0000000102eb1e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     39  PrivacyBrowser                      0x0000000102f6c331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     40  PrivacyBrowser                      0x0000000102f6c319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     41  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:22:18.437 PrivacyBrowser[7421:27154] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:22:18.438 PrivacyBrowser[7421:27154] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:22:18.439 PrivacyBrowser[7421:27154] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:22:18.439 PrivacyBrowser[7421:27154] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:22:18.505 PrivacyBrowser[7421:27154] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:22:18.506 PrivacyBrowser[7421:27154] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:22:18.507 PrivacyBrowser[7421:27154] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:22:18.780 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:22:18.780 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]: document controller: BrowserDocumentController
2026-10-29 08:22:18.780 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]: popup path, popup-nofield
2026-10-29 08:22:18.780 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]: NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
2026-10-29 08:22:18.781 PrivacyBrowser[7421:27154] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:22:18.781 PrivacyBrowser[7421:27154] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:22:18.783 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]: [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
2026-10-29 08:22:18.794 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:22:18.794 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:22:18.795 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]: setPopupWindowUnifiedFieldVisible:NO -> sent; isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   1   PrivacyBrowser                      0x0000000102d8fba4 PBPreprocessException + 48
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:19.093 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   26  PrivacyBrowser                      0x0000000102ea76d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   27  PrivacyBrowser                      0x0000000102e9bc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   28  PrivacyBrowser                      0x0000000102e9fcb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   29  PrivacyBrowser                      0x0000000102ea3dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   30  PrivacyBrowser                      0x0000000102d3cf90 $sIeg_IeyB_TR + 28
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   31  PrivacyBrowser                      0x0000000102d8fa08 PBCatchException + 36
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   32  PrivacyBrowser                      0x0000000102e9b990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   33  PrivacyBrowser                      0x0000000102e9e398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   34  PrivacyBrowser                      0x0000000102e9a3a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   35  PrivacyBrowser                      0x0000000102eb12e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   36  PrivacyBrowser                      0x0000000102eaf3e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   37  PrivacyBrowser                      0x0000000102eabdc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] SafariWindow[D55C1378]:   38  PrivacyBrowser                      0x0000000102eb1e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:22:19.094 PrivacyBrowser[7421:27154] Sa
```

Crash report `PrivacyBrowser-2026-10-29-082254.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:22:54.00 +0000",
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
    "incident_id": "A1DC5010-90A9-4408-856C-3125219CBF58"
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
    "byPid": 7421
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
PROBE sandboxed: true
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments unset, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments unset, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments unset, app unset, registered unset
PROBE profile store: persistent 4D857D83-10E0-479B-A406-CC7B38705D56
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup-mode
PROBE   NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
PROBE   [[BrowserWindowController alloc] initWithBrowsingMode:0 isPopupWindow:YES]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000102e63ba4 PBPreprocessException + 48
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
PROBE     26  PrivacyBrowser                      0x0000000102f7b6d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
PROBE     27  PrivacyBrowser                      0x0000000102f6fc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     28  PrivacyBrowser                      0x0000000102f73cb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     29  PrivacyBrowser                      0x0000000102f77dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     30  PrivacyBrowser                      0x0000000102e10f90 $sIeg_IeyB_TR + 28
PROBE     31  PrivacyBrowser                      0x0000000102e63a08 PBCatchException + 36
PROBE     32  PrivacyBrowser                      0x0000000102f6f990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     33  PrivacyBrowser                      0x0000000102f72398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
PROBE     34  PrivacyBrowser                      0x0000000102f6e3a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
PROBE     35  PrivacyBrowser                      0x0000000102f852e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
PROBE     36  PrivacyBrowser                      0x0000000102f833e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
PROBE     37  PrivacyBrowser                      0x0000000102f7fdc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     38  PrivacyBrowser                      0x0000000102f85e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     39  PrivacyBrowser                      0x0000000103040331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     40  PrivacyBrowser                      0x0000000103040319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     41  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:22:28.526 PrivacyBrowser[7718:27932] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:22:28.527 PrivacyBrowser[7718:27932] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:22:28.527 PrivacyBrowser[7718:27932] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:22:28.528 PrivacyBrowser[7718:27932] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:22:28.628 PrivacyBrowser[7718:27932] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:22:28.630 PrivacyBrowser[7718:27932] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:22:28.632 PrivacyBrowser[7718:27932] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:22:29.038 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:22:29.038 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]: document controller: BrowserDocumentController
2026-10-29 08:22:29.038 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]: popup path, popup-mode
2026-10-29 08:22:29.038 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]: NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
2026-10-29 08:22:29.038 PrivacyBrowser[7718:27932] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:22:29.038 PrivacyBrowser[7718:27932] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:22:29.041 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]: [[BrowserWindowController alloc] initWithBrowsingMode:0 isPopupWindow:YES]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
2026-10-29 08:22:29.041 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:22:29.041 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:22:30.049 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   1   PrivacyBrowser                      0x0000000102e63ba4 PBPreprocessException + 48
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
2026-10-29 08:22:30.050 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   26  PrivacyBrowser                      0x0000000102f7b6d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
2026-10-29 08:22:30.051 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   27  PrivacyBrowser                      0x0000000102f6fc0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:22:30.051 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   28  PrivacyBrowser                      0x0000000102f73cb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:22:30.051 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   29  PrivacyBrowser                      0x0000000102f77dbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:22:30.051 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   30  PrivacyBrowser                      0x0000000102e10f90 $sIeg_IeyB_TR + 28
2026-10-29 08:22:30.051 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   31  PrivacyBrowser                      0x0000000102e63a08 PBCatchException + 36
2026-10-29 08:22:30.051 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   32  PrivacyBrowser                      0x0000000102f6f990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:22:30.051 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   33  PrivacyBrowser                      0x0000000102f72398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
2026-10-29 08:22:30.051 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   34  PrivacyBrowser                      0x0000000102f6e3a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
2026-10-29 08:22:30.051 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   35  PrivacyBrowser                      0x0000000102f852e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
2026-10-29 08:22:30.051 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   36  PrivacyBrowser                      0x0000000102f833e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
2026-10-29 08:22:30.051 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   37  PrivacyBrowser                      0x0000000102f7fdc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:22:30.051 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   38  PrivacyBrowser                      0x0000000102f85e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:22:30.051 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   39  PrivacyBrowser                      0x0000000103040331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:22:30.051 PrivacyBrowser[7718:27932] SafariWindow[4D857D83]:   40
```

Crash report `PrivacyBrowser-2026-10-29-082240.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:22:40.00 +0000",
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
    "incident_id": "DF72C475-06CD-40F0-B184-DDAAA75757E1"
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
    "byPid": 7718
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
PROBE sandboxed: true
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments unset, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments unset, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments unset, app unset, registered unset
PROBE profile store: persistent F87244BB-21DE-477C-8CC2-B55CC43B5C3D
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup-hidden
PROBE   NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
PROBE   RAISED NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x105cef340
PROBE     0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000104adbba4 PBPreprocessException + 48
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
PROBE     12  PrivacyBrowser                      0x0000000104bebab8 $s14PrivacyBrowser06SafariB16WindowControllerC011createPopupE033_D5663EB8AEBCFB374BED3A50E441DB28LL_2ofSo8NSObjectCSgAC0G7VariantO_yXlXptF + 460
PROBE     13  PrivacyBrowser                      0x0000000104beb8b8 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU_ + 36
PROBE     14  PrivacyBrowser                      0x0000000104a88f90 $sIeg_IeyB_TR + 28
PROBE     15  PrivacyBrowser                      0x0000000104adba08 PBCatchException + 36
PROBE     16  PrivacyBrowser                      0x0000000104be7990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     17  PrivacyBrowser                      0x0000000104be95fc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 256
PROBE     18  PrivacyBrowser                      0x0000000104be63a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
PROBE     19  PrivacyBrowser                      0x0000000104bfd2e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
PROBE     20  PrivacyBrowser                      0x0000000104bfb3e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
PROBE     21  PrivacyBrowser                      0x0000000104bf7dc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     22  PrivacyBrowser                      0x0000000104bfde5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     23  PrivacyBrowser                      0x0000000104cb8331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     24  PrivacyBrowser                      0x0000000104cb8319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     25  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
PROBE   creating the controller raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x105cef340; caught, so the attempt ends and the process does not
PROBE   popup path, popup-hidden: giving up — raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x105cef340
PROBE   the profile's store was handed out 3 times during the attempt
PROBE     per-profile store factory asked for F87244BB-21DE-477C-8CC2-B55CC43B5C3D -> handed it persistent F87244BB-21DE-477C-8CC2-B55CC43B5C3D
PROBE     per-profile store factory asked for F87244BB-21DE-477C-8CC2-B55CC43B5C3D -> handed it persistent F87244BB-21DE-477C-8CC2-B55CC43B5C3D
PROBE     websiteDataStore read on WKWebViewConfiguration -> persistent F87244BB-21DE-477C-8CC2-B55CC43B5C3D
PROBE RESULT no window
PROBE activation policy afterwards: 0 (0 = regular, 1 = accessory)
PROBE FALLBACK in-process window: visible=true url=https://example.com/ title=Example Domain
PROBE wrote fallback-window.png (15545 bytes)
PROBE wrote fallback-page.png (76420 bytes)
PROBE step popup-hidden finished
2026-10-29 08:22:40.656 PrivacyBrowser[8282:29390] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:22:40.656 PrivacyBrowser[8282:29390] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:22:40.656 PrivacyBrowser[8282:29390] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:22:40.657 PrivacyBrowser[8282:29390] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:22:40.735 PrivacyBrowser[8282:29390] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:22:40.738 PrivacyBrowser[8282:29390] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:22:40.738 PrivacyBrowser[8282:29390] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:22:41.225 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:22:41.225 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]: document controller: BrowserDocumentController
2026-10-29 08:22:41.225 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]: popup path, popup-hidden
2026-10-29 08:22:41.225 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]: NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
2026-10-29 08:22:41.230 PrivacyBrowser[8282:29390] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:22:41.230 PrivacyBrowser[8282:29390] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:22:41.306 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]: RAISED NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x105cef340
2026-10-29 08:22:41.306 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:22:41.306 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   1   PrivacyBrowser                      0x0000000104adbba4 PBPreprocessException + 48
2026-10-29 08:22:41.306 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:22:41.306 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   3   CoreFoundation                      0x0000000188d803b4 -[NSObject(NSObject) __retain_OA] + 0
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   4   CoreFoundation                      0x0000000188c2ff68 ___forwarding___ + 1480
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   5   CoreFoundation                      0x0000000188c2f8e0 _CF_forwarding_prep_0 + 96
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   6   Safari                              0x00000001c0b2b1b8 -[BrowserDocument makeWindowControllers] + 168
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   7   Safari                              0x00000001c0cc9f4c -[BrowserDocumentController _createBrowserDocumentWithBrowsingMode:profileIdentifier:configuration:initialSize:options:] + 140
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   8   Safari                              0x00000001c0cc9e40 -[BrowserDocumentController _createBrowserDocumentWithBrowsingMode:profileIdentifier:initialSize:options:] + 248
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   9   Safari                              0x00000001c0cc6494 -[BrowserDocumentController createHiddenEmptyBrowserDocumentWithBrowsingMode:profileIdentifier:jitEnabled:isPopupWindow:restoringFromLastSession:initialSize:] + 64
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   10  Safari                              0x00000001c0d99320 +[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:restoringFromLastSession:] + 108
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   11  Safari                              0x00000001c0d993c4 +[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:] + 20
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   12  PrivacyBrowser                      0x0000000104bebab8 $s14PrivacyBrowser06SafariB16WindowControllerC011createPopupE033_D5663EB8AEBCFB374BED3A50E441DB28LL_2ofSo8NSObjectCSgAC0G7VariantO_yXlXptF + 460
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   13  PrivacyBrowser                      0x0000000104beb8b8 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU_ + 36
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   14  PrivacyBrowser                      0x0000000104a88f90 $sIeg_IeyB_TR + 28
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   15  PrivacyBrowser                      0x0000000104adba08 PBCatchException + 36
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   16  PrivacyBrowser                      0x0000000104be7990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   17  PrivacyBrowser                      0x0000000104be95fc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 256
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   18  PrivacyBrowser                      0x0000000104be63a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   19  PrivacyBrowser                      0x0000000104bfd2e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   20  PrivacyBrowser                      0x0000000104bfb3e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   21  PrivacyBrowser                      0x0000000104bf7dc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   22  PrivacyBrowser                      0x0000000104bfde5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:22:41.307 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   23  PrivacyBrowser                      0x0000000104cb8331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:22:41.308 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   24  PrivacyBrowser                      0x0000000104cb8319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
2026-10-29 08:22:41.308 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   25  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:22:41.312 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]: creating the controller raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x105cef340; caught, so the attempt ends and the process does not
2026-10-29 08:22:41.312 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]: popup path, popup-hidden: giving up — raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x105cef340
2026-10-29 08:22:41.312 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]: the profile's store was handed out 3 times during the attempt
2026-10-29 08:22:41.312 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   per-profile store factory asked for F87244BB-21DE-477C-8CC2-B55CC43B5C3D -> handed it persistent F87244BB-21DE-477C-8CC2-B55CC43B5C3D
2026-10-29 08:22:41.312 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   per-profile store factory asked for F87244BB-21DE-477C-8CC2-B55CC43B5C3D -> handed it persistent F87244BB-21DE-477C-8CC2-B55CC43B5C3D
2026-10-29 08:22:41.312 PrivacyBrowser[8282:29390] SafariWindow[F87244BB]:   websiteDataStore read on WKWebViewConfiguration -> persistent F87244BB-21DE-477C-8CC2-B55CC43B5C3D
```

## popup:crash-off — killed by SIGTRAP

```
PROBE step popup
PROBE macOS Version 26.6.2 (Build 25G83)
PROBE sandboxed: true
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments NO, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments NO, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments NO, app unset, registered unset
PROBE profile store: persistent A52C4E7D-0CA2-47EA-8D65-81AAD53021C6
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup
PROBE   NSApplicationCrashOnExceptions: reads false; arguments NO, app unset, registered unset
PROBE   [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x00000001042ebba4 PBPreprocessException + 48
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
PROBE     26  PrivacyBrowser                      0x00000001044036d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
PROBE     27  PrivacyBrowser                      0x00000001043f7c0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     28  PrivacyBrowser                      0x00000001043fbcb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     29  PrivacyBrowser                      0x00000001043ffdbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     30  PrivacyBrowser                      0x0000000104298f90 $sIeg_IeyB_TR + 28
PROBE     31  PrivacyBrowser                      0x00000001042eba08 PBCatchException + 36
PROBE     32  PrivacyBrowser                      0x00000001043f7990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     33  PrivacyBrowser                      0x00000001043fa398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
PROBE     34  PrivacyBrowser                      0x00000001043f63a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
PROBE     35  PrivacyBrowser                      0x000000010440d2e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
PROBE     36  PrivacyBrowser                      0x000000010440b3e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
PROBE     37  PrivacyBrowser                      0x0000000104407dc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     38  PrivacyBrowser                      0x000000010440de5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     39  PrivacyBrowser                      0x00000001044c8331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     40  PrivacyBrowser                      0x00000001044c8319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     41  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:22:46.009 PrivacyBrowser[8411:29863] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:22:46.010 PrivacyBrowser[8411:29863] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:22:46.010 PrivacyBrowser[8411:29863] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:22:46.010 PrivacyBrowser[8411:29863] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:22:46.099 PrivacyBrowser[8411:29863] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:22:46.109 PrivacyBrowser[8411:29863] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:22:46.109 PrivacyBrowser[8411:29863] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:22:46.566 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:22:46.567 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]: document controller: BrowserDocumentController
2026-10-29 08:22:46.567 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]: popup path, popup
2026-10-29 08:22:46.567 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]: NSApplicationCrashOnExceptions: reads false; arguments NO, app unset, registered unset
2026-10-29 08:22:46.570 PrivacyBrowser[8411:29863] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:22:46.570 PrivacyBrowser[8411:29863] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:22:46.589 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]: [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
2026-10-29 08:22:46.589 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:22:46.589 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   1   PrivacyBrowser                      0x00000001042ebba4 PBPreprocessException + 48
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:22:47.468 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
2026-10-29 08:22:47.469 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
2026-10-29 08:22:47.469 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   26  PrivacyBrowser                      0x00000001044036d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
2026-10-29 08:22:47.469 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   27  PrivacyBrowser                      0x00000001043f7c0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:22:47.469 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   28  PrivacyBrowser                      0x00000001043fbcb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:22:47.469 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   29  PrivacyBrowser                      0x00000001043ffdbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:22:47.469 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   30  PrivacyBrowser                      0x0000000104298f90 $sIeg_IeyB_TR + 28
2026-10-29 08:22:47.469 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   31  PrivacyBrowser                      0x00000001042eba08 PBCatchException + 36
2026-10-29 08:22:47.469 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   32  PrivacyBrowser                      0x00000001043f7990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:22:47.469 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   33  PrivacyBrowser                      0x00000001043fa398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
2026-10-29 08:22:47.469 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   34  PrivacyBrowser                      0x00000001043f63a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
2026-10-29 08:22:47.469 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   35  PrivacyBrowser                      0x000000010440d2e8 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 184
2026-10-29 08:22:47.469 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   36  PrivacyBrowser                      0x000000010440b3e8 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1040
2026-10-29 08:22:47.469 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   37  PrivacyBrowser                      0x0000000104407dc1 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:22:47.469 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   38  PrivacyBrowser                      0x000000010440de5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:22:47.469 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   39  PrivacyBrowser                      0x00000001044c8331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:22:47.469 PrivacyBrowser[8411:29863] SafariWindow[A52C4E7D]:   40  PrivacyBrowser                      0x00000001044c8319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5Nev
```

Crash report `PrivacyBrowser-2026-10-29-082249.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:22:49.00 +0000",
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
    "incident_id": "3F7BCF6F-472D-4E2F-AF12-0B306AECFEB2"
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
    "byPid": 8411
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
PROBE sandboxed: true
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments NO, app 1, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments NO, app 1, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments NO, app 1, registered unset
PROBE profile store: persistent 287AC9DF-9053-4CEA-810A-E2005205B860
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup
PROBE   NSApplicationCrashOnExceptions: reads false; arguments NO, app 1, registered unset
PROBE   [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000104197ba4 PBPreprocessException + 48
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
PROBE     26  PrivacyBrowser                      0x00000001042af6d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
PROBE     27  PrivacyBrowser                      0x00000001042a3c0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     28  PrivacyBrowser                      0x00000001042a7cb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     29  PrivacyBrowser                      0x00000001042abdbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     30  PrivacyBrowser                      0x0000000104144f90 $sIeg_IeyB_TR + 28
PROBE     31  PrivacyBrowser                      0x0000000104197a08 PBCatchException + 36
PROBE     32  PrivacyBrowser                      0x00000001042a3990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     33  PrivacyBrowser                      0x00000001042a6398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
PROBE     34  PrivacyBrowser                      0x00000001042a23a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
PROBE     35  PrivacyBrowser                      0x00000001042a05e8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 540
PROBE     36  PrivacyBrowser                      0x00000001042b4fb0 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZ04$s14a9Browser20cde17O10windowStep33_9ijklmno11LLyyYaFZSo8p10CSgAA0cB16qr6C_So18stU24C10Foundation3URLVtXEfU_Tf1cn_nTY0_ + 1092
PROBE     37  PrivacyBrowser                      0x00000001042b3f49 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ5_ + 1
PROBE     38  PrivacyBrowser                      0x00000001042b9e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     39  PrivacyBrowser                      0x0000000104374331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     40  PrivacyBrowser                      0x0000000104374319 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     41  libswift_Concurrency.dylib          0x000000028e2afec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:22:56.271 PrivacyBrowser[8535:30260] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:22:56.272 PrivacyBrowser[8535:30260] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:22:56.272 PrivacyBrowser[8535:30260] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:22:56.272 PrivacyBrowser[8535:30260] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:22:56.304 PrivacyBrowser[8535:30260] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:22:56.305 PrivacyBrowser[8535:30260] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:22:56.305 PrivacyBrowser[8535:30260] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:22:56.453 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:22:56.453 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]: document controller: BrowserDocumentController
2026-10-29 08:22:56.453 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]: popup path, popup
2026-10-29 08:22:56.453 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]: NSApplicationCrashOnExceptions: reads false; arguments NO, app 1, registered unset
2026-10-29 08:22:56.453 PrivacyBrowser[8535:30260] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:22:56.453 PrivacyBrowser[8535:30260] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:22:56.457 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]: [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
2026-10-29 08:22:56.457 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:22:56.457 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   0   CoreFoundation                      0x0000000188cbf1f0 __exceptionPreprocess + 176
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   1   PrivacyBrowser                      0x0000000104197ba4 PBPreprocessException + 48
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   2   libobjc.A.dylib                     0x000000018873a91c objc_exception_throw + 88
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   3   Foundation                          0x000000018a4b90bc -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   4   Safari                              0x00000001c0b3c100 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   5   Safari                              0x00000001c0b3b00c -[UnifiedField _layOutFaviconAndMainContentView] + 2180
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   6   Safari                              0x00000001c0b3a670 -[UnifiedField layout] + 104
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   7   AppKit                              0x000000018d5b150c __getCGDisplayListGetHashSymbolLoc_block_invoke + 1516
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   8   AppKit                              0x000000018d5b1534 __getCGDisplayListGetHashSymbolLoc_block_invoke + 1556
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   9   AppKit                              0x000000018d5767a0 block_destroy_helper + 9428
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   10  AppKit                              0x000000018d576dec block_destroy_helper + 11040
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   11  AppKit                              0x000000018ddba078 ___NSViewLayout_block_invoke + 624
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   12  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   13  AppKit                              0x000000018d0cbc10 _NSViewLayout + 96
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   14  AppKit                              0x000000018ddafd6c __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   15  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   16  AppKit                              0x000000018d0cbba4 -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   17  AppKit                              0x000000018ddb093c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:22:56.763 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   18  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   19  AppKit                              0x000000018d0cb780 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   20  AppKit                              0x000000018d0c72d8 NSPerformVisuallyAtomicChange + 128
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   21  AppKit                              0x000000018d0cb710 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   22  Safari                              0x00000001c0b30e78 -[BrowserWindowController windowDidLoad] + 1032
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   23  AppKit                              0x000000018d1e81a8 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   24  Safari                              0x00000001c0b30a50 -[WindowController _windowDidLoad] + 52
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   25  AppKit                              0x000000018d1e438c -[NSWindowController window] + 100
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   26  PrivacyBrowser                      0x00000001042af6d4 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 1092
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   27  PrivacyBrowser                      0x00000001042a3c0c $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   28  PrivacyBrowser                      0x00000001042a7cb8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   29  PrivacyBrowser                      0x00000001042abdbc $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   30  PrivacyBrowser                      0x0000000104144f90 $sIeg_IeyB_TR + 28
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   31  PrivacyBrowser                      0x0000000104197a08 PBCatchException + 36
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   32  PrivacyBrowser                      0x00000001042a3990 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   33  PrivacyBrowser                      0x00000001042a6398 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3740
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   34  PrivacyBrowser                      0x00000001042a23a8 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 916
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   35  PrivacyBrowser                      0x00000001042a05e8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 540
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   36  PrivacyBrowser                      0x00000001042b4fb0 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZ04$s14a9Browser20cde17O10windowStep33_9ijklmno11LLyyYaFZSo8p10CSgAA0cB16qr6C_So18stU24C10Foundation3URLVtXEfU_Tf1cn_nTY0_ + 1092
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   37  PrivacyBrowser                      0x00000001042b3f49 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ5_ + 1
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   38  PrivacyBrowser                      0x00000001042b9e5d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   39  PrivacyBrowser                      0x0000000104374331 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:22:56.764 PrivacyBrowser[8535:30260] SafariWindow[287AC9DF]:   40  PrivacyBrowser       
```

Crash report `PrivacyBrowser-2026-10-29-082257.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:22:57.00 +0000",
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
    "incident_id": "7F53427F-ACD4-4C57-945B-068F5745A579"
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
    "byPid": 8535
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
