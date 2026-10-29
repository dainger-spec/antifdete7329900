# Framework window probe

macOS 15.7.9 (24G830), arm64, SIP: System Integrity Protection status: disabled.
built with SDK 15.5, Xcode 16.4 Build version 16F6
app: build/unsandboxed/PrivacyBrowser.app

| step | outcome | seconds | why |
|---|---|---|---|
| image | exited 0 | 1.0 |  |
| classes | exited 0 | 0.2 |  |
| selectors | exited 0 | 1.2 |  |
| appcontroller | exited 0 | 0.1 |  |
| windowcontroller | exited 0 | 0.1 |  |
| documentcontroller | exited 0 | 0.1 |  |
| documentcontroller-create | exited 0 | 0.5 |  |
| webconfig | exited 0 | 0.2 |  |
| shared | exited 0 | 0.1 |  |
| create-direct | killed by SIGTRAP | 1.0 | SIGNAL 5 / Trace/BPT trap: 5 / EXC_BREAKPOINT SIGTRAP |
| create | exited 0 | 0.6 | raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value |
| create-bootstrap | exited 0 | 0.4 | raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value |
| window | exited 0 | 2.2 | raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; no window |
| popupfield | exited 0 | 0.2 |  |
| popup | exited 0 | 1.2 | raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; no window |
| popup-nofield | exited 0 | 1.0 | raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; no window |
| popup-mode | exited 0 | 0.9 | raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; no window |
| popup-hidden | exited 0 | 0.8 | raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x12f60da60; no window |
| popup:crash-off | exited 0 | 0.9 | raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; no window |
| window:chrome | exited 0 | 1.7 | raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; no window |

## image — exited 0

```
PROBE step image
PROBE macOS Version 15.7.9 (Build 24G830)
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
PROBE   /System/Library/PrivateFrameworks/SafariSafeBrowsing.framework/Versions/A/SafariSafeBrowsing
PROBE   /System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/WebCore
PROBE   /System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/Frameworks/libANGLE-shared.dylib
PROBE   /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   /System/Library/PrivateFrameworks/SafariFoundation.framework/Versions/A/SafariFoundation
PROBE   /System/Library/PrivateFrameworks/SafariSwift.framework/Versions/A/SafariSwift
PROBE   /System/Library/Frameworks/SafariServices.framework/Versions/A/SafariServices
PROBE   /System/Library/PrivateFrameworks/SafariShared.framework/Versions/A/SafariShared
PROBE   /System/Library/PrivateFrameworks/SafariSharedUI.framework/Versions/A/SafariSharedUI
PROBE   /System/Library/PrivateFrameworks/SafariCore.framework/Versions/A/SafariCore
PROBE what the framework bundle holds on disk:
PROBE   /System/Library/PrivateFrameworks/Safari.framework: 3 entries; PlugIns, Resources, Versions
PROBE   /System/Library/PrivateFrameworks/Safari.framework/Versions/A: 3 entries; PlugIns, Resources, _CodeSignature
PROBE   /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Resources: 67 entries, 42 .lproj (de.lproj, he.lproj, en_AU.lproj, ar.lproj); ContactsAutoFillChoicesMenuItemView.nib, ExtensionCheckmark.svg, ar.lproj, de.lproj, el.lproj, en.lproj, en_AU.lproj, he.lproj, ja.lproj, uk.lproj
PROBE   /System/Library/PrivateFrameworks/Safari.framework/Resources: 67 entries, 42 .lproj (de.lproj, he.lproj, en_AU.lproj, ar.lproj); ContactsAutoFillChoicesMenuItemView.nib, ExtensionCheckmark.svg, ar.lproj, de.lproj, el.lproj, en.lproj, en_AU.lproj, he.lproj, ja.lproj, uk.lproj
PROBE   Bundle(path:) -> loaded=false, identifier=com.apple.Safari.framework
PROBE step image finished
2026-10-29 08:19:07.619 PrivacyBrowser[2298:10940] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:07.619 PrivacyBrowser[2298:10940] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:07.619 PrivacyBrowser[2298:10940] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:07.619 PrivacyBrowser[2298:10940] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:08.365 PrivacyBrowser[2298:10940] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## classes — exited 0

```
PROBE step classes
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE classes in the image: 1012
PROBE wrote framework-classes.txt (27942 bytes)
PROBE *AppController*: 3 -> AppController, AppControllerTouchBarProvider, WebAppController
PROBE *BrowserWindowController*: 1 -> BrowserWindowController
PROBE *BrowserViewController*: 3 -> BrowserViewController, BrowserViewControllerNavigationManager, BrowserViewControllerWindowConfiguration
PROBE *WindowController*: 5 -> BrowserWindowController, FullscreenUnifiedFieldWindowController, OverlayStatusWindowController, TabPreviewWindowController, WindowController
PROBE *Profile*: 11 -> AcceptSharedTabGroupInProfileAlertController, CreateProfilePreferencesViewController, ExtensionsProfilesPreferencesViewController, GeneralProfilesPreferencesViewController, ProfileIconButton, ProfileIconPickerCollectionViewController, ProfileIconPickerCollectionViewItem, ProfileIconPickerViewController, ProfileTitleTextField, ProfilesPreferences, ProfilesPreferencesTableCellView
PROBE *WebView*: 2 -> VisualTabPickerWebViewThumbnailView, WebViewController
PROBE *TabContent*: 2 -> TabContentView, TabContentViewController
PROBE *BrowserWindow*: 8 -> AutomationBrowserWindow, BrowserWindow, BrowserWindowContentSplitViewController, BrowserWindowContentViewController, BrowserWindowController, BrowserWindowPersistentState, BrowserWindowTabView, BrowserWindowTabViewController
PROBE step classes finished
2026-10-29 08:19:08.602 PrivacyBrowser[2307:11068] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:08.603 PrivacyBrowser[2307:11068] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:08.603 PrivacyBrowser[2307:11068] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:08.603 PrivacyBrowser[2307:11068] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:08.612 PrivacyBrowser[2307:11068] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## selectors — exited 0

```
PROBE step selectors
PROBE macOS Version 15.7.9 (Build 24G830)
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
PROBE   WebAppController: newWindowMenuItem, setNewWindowMenuItem:
PROBE   MacSafariBookmarkDBAccess: _fallbackNewWindowBehaviorBookmarkFolderProvider
PROBE   BookmarksController: bookmarkForNewWindowTabsPreferenceForProfileIdentifier:
PROBE   BookmarkSource: goToContentItemInNewWindow:
PROBE   BookmarksViewController: goToContentItemInNewWindow:
PROBE   BrowserApplication: createNewWindowFromTouchBarProvider:
PROBE   BrowserDocumentController: _newTabInNewWindowWithBrowsingMode:sender:
PROBE   BrowserUIDelegate: _appendNewWindowAndTabMenuItemsToMenu:newWindowTitle:newWindowAction:newTabTitle:newTabAction:alternativeNewWindowTitle:alternativeNewWindowAction:enableNewWindowMenuItems:contextMenuInfo:, _appendNewWindowAndTabMenuItemsToMenu:prefixString:newNonPrivateWindowAction:newPrivateWindowAction:newAutomationWindowAction:newTabAction:contextMenuInfo:, _appendOpenFrameInNewWindowAndTabMenuItemsToMenu:openFrameInNewWindowExistingMenuItem:contextMenuInfo:, _appendOpenImageInNewWindowAndTabMenuItemsToMenu:openImageInNewWindowExistingMenuItem:contextMenuInfo:, _appendOpenLinkInNewWindowAndTabMenuItemsToMenu:openLinkInNewWindowExistingMenuItem:contextMenuInfo:, _appendOpenMediaInNewWindowAndTabMenuItemsToMenu:openMediaInNewWindowExistingMenuItem:elementType:contextMenuInfo:, _appendOpenQRCodePayloadURLInNewWindowAndTabMenuItemsToMenu:contextMenuInfo:, _openFrameInNewWindowFromContextMenuInfo:windowPolicy:
PROBE   BrowserViewController: browserWKViewDidMoveToNewWindow
PROBE   BrowserWindowController: _moveTabGroupTabsToNewWindow:, _moveTabToNewWindow:, _moveTabsToNewWindow:, _newWindowShouldBeUnbuffered, _notifyPageAboutBarsStatesAfterMovingToNewWindow:, _openBookmarksInTabsForNewWindow, _replaceEmptyTabInNewWindowWithTabs:, _shouldUseOpenBookmarksInTabsNewWindowBehavior
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
2026-10-29 08:19:08.836 PrivacyBrowser[2309:11086] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:08.837 PrivacyBrowser[2309:11086] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:08.837 PrivacyBrowser[2309:11086] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:08.837 PrivacyBrowser[2309:11086] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:08.876 PrivacyBrowser[2309:11086] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## appcontroller — exited 0

```
PROBE step appcontroller
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE classes to dump: AppController
PROBE AppController: AppController <- NSObject
PROBE   691 instance methods, 8 class methods, 195 ivars, 121 properties
PROBE   *init*: _initializeInspectorProcessContextForProfileIdentifier:, _initializeNSUserDefaults, _initializeProcessContextForProfileIdentifier:, _initializeProcessContextWithoutJITForProfileIdentifier:, _openURL:forcingHTMLMIMEType:bundleIdentifierOfApplicationThatInitiatedNavigation:, init, initializationMessages, initializeShareMenuItemInFileMenu:, setInjectedBundleInitializationMessagesData:forKey:
PROBE   *window*: _OKToCloseBrowserWindowsForExplicitCloseAllCommand:, _addNewProfileWindowOptionsWithProfiles:toApplicationDockMenuOrSubmenu:, _browserStateFromCurrentSessionIgnoringPrivateWindows:encryptionProvider:, _collectWindowsAndTabsDataTimerFired:, _consolidateTabsAndWindowsNow, _copyUnnamedOrPrivateTabGroupsFromWindowController:toWindowState:, _createBundleForDownloadWithSuggestedFilename:downloadLocationRequestType:inBrowserWindowController:completionHandler:, _createNewWindowWithFrontmostProfile:, _didFinishRestoringWindows, _eventIsCloseTabOrWindowKeyEquivalent:, _eventIsNewPrivateWindowKeyEquivalent:, _eventIsNewTabOrWindowKeyEquivalent:, _eventModifierFlagsForNewWindow, _hasEverShownWindow
PROBE   *profile*: _addCreateOrManageProfilesMenuItem, _addNewProfileWindowOptionsWithProfiles:toApplicationDockMenuOrSubmenu:, _createExtensionControllersIfNeededForProfileServerID:, _createNewWindowWithFrontmostProfile:, _createOrManageProfilesMenuItemTitle, _historiesForProfiles, _initializeInspectorProcessContextForProfileIdentifier:, _initializeProcessContextForProfileIdentifier:, _initializeProcessContextWithoutJITForProfileIdentifier:, _inspectorProcessPoolForProfileIdentifier:createIfNeeded:, _loadExtensionsInProfile:, _newProfileWindowFromDock:, _newWindowWithDefaultProfile:, _newWindowWithFrontmostProfile:
PROBE   *webview*: downloadsManager:browserWindowControllerForWebView:getDownloadStartOriginInWindow:, downloadsManager:createBundleForDownloadOnWebView:fromSecurityOrigin:originatingURL:suggestedFilename:downloadLocationRequestType:completionHandler:, downloadsManager:willStartDownloadAtURL:downloadProgressEntry:forWebView:, notifyAddedLinkPreviewMetadata:toUserActivity:webView:
PROBE   *datastore*: _processPushMessages:inDataStore:completionHandler:, _setWKWebsiteDataStoreDelegate, prewarmAndRemoveOrphanedProfileDataStores, websiteDataStore:domain:didExceedMemoryFootprintThreshold:withPageCount:processLifetime:inForeground:wasPrivateRelayed:canSuspend:, websiteDataStore:domain:didOpenDomainViaWindowOpen:withProperty:directly:, websiteDataStore:navigateToNotificationActionURL:, websiteDataStore:openWindow:fromServiceWorkerOrigin:completionHandler:, websiteDataStore:workerOrigin:updatedAppBadge:
PROBE   *configuration*: _defaultProcessConfiguration, _focusConfigurationChanged, _tabCollectionConfiguration, toggleJavaScriptConfigurationEnabled:, validate_toggleJavaScriptConfigurationEnabled:
PROBE   *shared*: _presentSharedTabGroupErrorWithMessage:informativeText:, _presentSharedTabGroupsPendingAcceptanceError, _presentSharedTabGroupsUnsupportedError, didFetchRecentlyAcceptedSharedTabGroupWithUUID:acceptedShareDate:, sharedAppController
PROBE   *new*: _addNewProfileWindowOptionsWithProfiles:toApplicationDockMenuOrSubmenu:, _clearInvalidCertificateBypassesOlderThanOneWeek, _createNewWindowWithFrontmostProfile:, _eventIsNewPrivateWindowKeyEquivalent:, _eventIsNewTabOrWindowKeyEquivalent:, _eventModifierFlagsForNewWindow, _isWhatsNewInSafariEnabled, _newPrivateWindowFromDock:, _newProfileWindowFromDock:, _newWindowFromDock:, _newWindowWithDefaultProfile:, _newWindowWithFrontmostProfile:, _prepareBrowserContentViewControllerForNewUserActivity, _prepareBrowserContentViewControllerForNewUserActivityUsingPrivateBrowsingForNewWindow:
PROBE   *tab*: _allTabsWithExtensionContentLoadedForExtensionHost:, _collectWindowsAndTabsDataTimerFired:, _computeCurrentSafariTabState, _computeLastSessionTabCount, _consolidateTabsAndWindowsNow, _copyTabsFromTabGroup:toTabGroupWithUUID:isPrivate:, _copyUnnamedOrPrivateTabGroupsFromWindowController:toWindowState:, _duplicateLastSessionStateAndSaveToDatabase, _ensureTabSnapshotVendor, _eventIsCloseTabOrWindowKeyEquivalent:, _eventIsNewTabOrWindowKeyEquivalent:, _eventIsOldSelectNextPreviousTabKeyEquivalent:direction:, _eventIsSelectNextTabKeyEquivalent:, _eventIsSelectPreviousTabKeyEquivalent:
PROBE   ivars naming a store or a profile: _didRestoreStateDuringLaunch  B | _createOrManageProfilesMenuItem  @"NSMenuItem" | _newDefaultProfileWindowMenuItem  @"NSMenuItem" | _newProfileWindowMenuItem  @"NSMenuItem" | _lastMenuUpdateProfileIdentifiers  @"NSArray" | _focusProfileIdentifier  @"NSString" | _profileServerIDToAppExtensionsControllers  @"NSMutableDictionary" | _profileServerIDToWebExtensionsControllers  @"NSMutableDictionary" | _profileServerIDToContentBlockerManagers  @"NSMutableDictionary" | _profileServerIDToUserContentController  @"NSMutableDictionary" | _acceptSharedTabGroupInProfileAlert  @"AcceptSharedTabGroupInProfileAlertController" | _profileIdentifiersToSuggestionsManagers  @"NSMutableDictionary" | _webAppVisitedLinkStore  @"_WKVisitedLinkStore" | _profilePreferenceManager  @"WBSProfilePreferenceManager"
PROBE wrote framework-AppController.txt (52239 bytes)
PROBE step appcontroller finished
2026-10-29 08:19:10.039 PrivacyBrowser[2314:11125] SafariLoader: classNames -> nil (framework image not in the loaded image list)
2026-10-29 08:19:10.040 PrivacyBrowser[2314:11125] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:10.040 PrivacyBrowser[2314:11125] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:10.040 PrivacyBrowser[2314:11125] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:10.040 PrivacyBrowser[2314:11125] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:10.048 PrivacyBrowser[2314:11125] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## windowcontroller — exited 0

```
PROBE step windowcontroller
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE classes to dump: BrowserWindowController
PROBE BrowserWindowController: BrowserWindowController <- WindowController <- NSWindowController <- NSResponder <- NSObject
PROBE   1420 instance methods, 21 class methods, 186 ivars, 166 properties
PROBE   *init*: _canInitiateTabGroupShare, _canInitiateTabGroupShareFromShareButton, didStartBrowserInitiatedLoadInBrowserViewController:, init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
PROBE   *window*: _backgroundLoadConfigurationForNonSpeculativeLoadInCurrentWindow, _backgroundLoadConfigurationForSpeculativeLoadInCurrentWindow, _canCloseTabWithoutClosingWindow:includingLastUnpinnedTab:, _canConsolidateTabGroupInWindowMerge:, _closeTabsAndMarkAsReusableWhileClosingWindow:, _closeWindowAfterChecks, _closeWindowIfNoUnpinnedTabsLeft, _closeWindowIfPossible, _destinationWindowForDetachedTabBarViewItems:withActiveTabIndex:, _detachedWindowImageForDraggedTabBarViewItem:, _didFinishTransitionAnimationForWindow:, _displayCloseWindowConfirmSheetForLocalTabGroupIfNecessary, _displayCloseWindowConfirmSheetForPIPIfNecessary, _ensureLocationBarIsVisibleIfWindowIsNotInFullScreen
PROBE   *profile*: _namedTabGroupsForActiveProfile, _profileIdentifierForTab:, canSwitchToAnotherProfile, closeProfileWindow:, hasMultipleProfiles, isInDefaultProfile, isInSameProfileAsBrowserWindowController:, profile, profileIdentifier, profileWindow:selectProfile:, profileWindow:selectTabGroup:, shouldShowProfileTitle, startPageShouldShowProfileTitle, tabGroupManager:didUpdateProfileWithIdentifier:difference:
PROBE   *webview*: _updateTitlebarColorFromWebView:, _updateTitlebarColorFromWebView:forceUpdate:, _updateWebAppTitlebarColorFromWebView:forceUpdate:, currentWebViewSize
PROBE   *configuration*: _backgroundLoadConfigurationForNonSpeculativeLoadInCurrentWindow, _backgroundLoadConfigurationForSpeculativeLoadInCurrentWindow, _toggleLocationBar:suppressToolbarConfigurationAutosave:, _toggleLocationBarWithoutSavingConfiguration, didClearBlockedWindowConfigurationCaches, makeBrowserViewControllerForBackgroundLoadController:configuration:urls:, makeBrowserViewControllerInTabAtIndex:configuration:andSelect:, makeBrowserViewControllerInTabOfType:configuration:andSelect:
PROBE   *shared*: _presentAttributedSharedTabNoticeWithMessage:forParticipantWithRecordID:inSharedTabGroupWithUUID:, _switchToRecentlyJoinedSharedTabGroupIfNeeded, _titleForSharedWithYouMenuItemBasedOnViewVisibility, didAddTabWithUUID:title:inSharedTabGroupWithUUID:byParticipantWithRecordID:, didChangeBackgroundImageInSharedTabGroupWithUUID:byParticipantWithRecordID:, didChangeScopedFavoritesInSharedTabGroupWithUUID:byParticipantWithRecordID:, didNavigateInTabWithUUID:title:inSharedTabGroupWithUUID:byParticipantWithRecordID:, didRemoveTabWithUUID:title:inSharedTabGroupWithUUID:byParticipantWithRecordID:, participants:didJoinSharedTabGroupWithUUID:, participants:didLeaveSharedTabGroupWithUUID:, switchToRecentlyAcceptedSharedTabGroupWithUUID:acceptedShareDate:, toggleSharedWithYou:
PROBE   *new*: _applyNewBrowserViewBehavior:toBrowserViewController:usingReferenceBrowserViewController:, _createBrowserViewControllerAsynchronouslyInNewTabOfType:respectingNewTabBehavior:tabCreationOptions:completionHandler:, _createBrowserViewControllerInNewTabOfType:respectingNewTabBehavior:andSelect:, _didCreateBrowserViewController:formerlySelectedBrowserViewController:respectingNewTabBehavior:selectingOnCreation:, _didSelectNewTab:withLastSelectedTab:, _isTabEquivalentToNewlyCreatedTabRespectingNewTabBehavior:, _moveTabGroupTabsToNewWindow:, _moveTabToNewWindow:, _moveTabsToNewWindow:, _newTabTypeRespectingVisualTabPickerVisibility:, _newWindowShouldBeUnbuffered, _notifyPageAboutBarsStatesAfterMovingToNewWindow:, _openBookmarksInTabsForNewWindow, _replaceEmptyTabInNewWindowWithTabs:
PROBE   *tab*: _acceptTabDrop:index:, _addPlaceholderContentToTab:, _allowsPinnedTabsInTabGroup:, _allowsScrollingPinnedTabs, _alwaysShowTabBar, _applyTabSelectionStateUpdateForTab:previouslySelectedTab:selectedTabViewItems:completionHandler:, _audioMenuTabMenuItemClicked:, _beginUniqueBackgroundLoadWithURLs:tabLabel:isSpeculative:identifier:httpReferrer:canAttemptUpgradingRequestURLToHTTPS:, _bookmarkForBrowserTabViewItem:, _browserTabPersistentStateForTab:, _browserTabViewItemForUnifiedTabBarItem:, _browserTabViewItemWithBackgroundNavigationBackgroundLoad:, _browserTabViewItemsForUnifiedTabBarItems:, _browserTabsDidChange
PROBE   ivars naming a store or a profile: _tabIndexToSelectAfterPinnedTabsAreRestored  Q | _profileWindow  @"WBProfileWindow"
PROBE wrote framework-BrowserWindowController.txt (85360 bytes)
PROBE step windowcontroller finished
2026-10-29 08:19:10.140 PrivacyBrowser[2315:11134] SafariLoader: classNames -> nil (framework image not in the loaded image list)
2026-10-29 08:19:10.141 PrivacyBrowser[2315:11134] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:10.141 PrivacyBrowser[2315:11134] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:10.141 PrivacyBrowser[2315:11134] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:10.142 PrivacyBrowser[2315:11134] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:10.151 PrivacyBrowser[2315:11134] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## documentcontroller — exited 0

```
PROBE step documentcontroller
PROBE macOS Version 15.7.9 (Build 24G830)
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
PROBE   226 instance methods, 1 class methods, 13 ivars, 18 properties
PROBE   *init*: _commonBrowserDocumentInitWithContentsOfRequest:browserViewController:, _commonInitWithRequest:browsingMode:isPopupWindow:, displayInitialContents, hasInitialContents, init, initWithBrowsingMode:configuration:profileIdentifier:isPopupWindow:restoringFromLastSession:, initWithContentsOfRequest:browsingMode:profileIdentifier:automationSessionIdentifier:isPopupWindow:, initWithContentsOfURL:ofType:
PROBE   *window*: _commonInitWithRequest:browsingMode:isPopupWindow:, _openURL:withWindowPolicy:, _selectedTabsInWindow, browserWindowController, initWithBrowsingMode:configuration:profileIdentifier:isPopupWindow:restoringFromLastSession:, initWithContentsOfRequest:browsingMode:profileIdentifier:automationSessionIdentifier:isPopupWindow:, isPopupWindow, makeWindowControllers, pageCollectionControllerWindowWillClose:, profileDisplayTitleInWindow, removeWindowController:, restoreDocumentWindowWithIdentifier:state:completionHandler:, setProfileDisplayTitleInWindow:, setShouldOpenWindowBehindFrontmost:
PROBE   *profile*: getBytecodeProfile:, initWithBrowsingMode:configuration:profileIdentifier:isPopupWindow:restoringFromLastSession:, initWithContentsOfRequest:browsingMode:profileIdentifier:automationSessionIdentifier:isPopupWindow:, profileDisplayTitleInWindow, profileIdentifier, saveSamplingProfilerOutput:, setProfileDisplayTitleInWindow:, validate_getBytecodeProfile:, validate_saveSamplingProfilerOutput:
PROBE   *configuration*: initWithBrowsingMode:configuration:profileIdentifier:isPopupWindow:restoringFromLastSession:, makeBrowserViewControllerWithConfiguration:
PROBE   *new*: goToRequest:withTabLabel:inNewProcess:, setSuppressRelatingNewBlankTabs:, updateNewTabPositionValue:, validate_setSuppressRelatingNewBlankTabs:, validate_updateNewTabPositionValue:
PROBE   *tab*: _addBookmarksForTabViewItems:, _addReadingListItemsForTabs:, _numberOfTabsToPotentiallyAddToBookmarksOrReadingList, _selectedTabsInWindow, addBookmarksForTabs:, addReadingListItemsForTabs:, canAddBookmarksForTabs, canAddBookmarksForTabs:, currentBrowserViewControllerIgnoringVisualTabPickerVisibility, firstTabOpensWithStartPage, goToRequest:withTabLabel:, goToRequest:withTabLabel:inNewProcess:, isConsolidatable, setApplyPositionToAllBlankTabs:
PROBE   ivars naming a store or a profile: _profileIdentifier  @"NSString" | _profileDisplayTitleInWindow  @"NSString"
PROBE wrote framework-BrowserDocumentController.txt (17609 bytes)
PROBE step documentcontroller finished
2026-10-29 08:19:10.276 PrivacyBrowser[2317:11144] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:10.276 PrivacyBrowser[2317:11144] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:10.277 PrivacyBrowser[2317:11144] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:10.277 PrivacyBrowser[2317:11144] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:10.285 PrivacyBrowser[2317:11144] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## documentcontroller-create — exited 0

```
PROBE step documentcontroller-create
PROBE macOS Version 15.7.9 (Build 24G830)
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
2026-10-29 08:19:10.751 PrivacyBrowser[2318:11148] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:10.751 PrivacyBrowser[2318:11148] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:10.752 PrivacyBrowser[2318:11148] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:10.752 PrivacyBrowser[2318:11148] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:10.765 PrivacyBrowser[2318:11148] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## webconfig — exited 0

```
PROBE step webconfig
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE configuration factories: _webViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:relatedWebView:groupIdentifier:preferences:userContentController:jitEnabled:preferencesManager:, _webViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:relatedWebView:groupIdentifier:preferences:userContentController:webExtensionsController:jitEnabled:preferencesManager:, automationPreferencesWithConfiguration:, contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:, contentWebViewConfigurationForBrowsingMode:profileIdentifier:jitEnabled:, readerWebViewConfigurationForBrowsingMode:profileIdentifier:relatedWebView:, webExtensionWebViewConfigurationForExtension:relatedWebView:, webExtensionWebViewConfigurationForExtensionsController:relatedWebView:
PROBE calling +[WebKitPreferencesManager contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:] for profile C6D35430-6C8D-41FA-BEB0-84D2F7959DDD …
PROBE   contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier: -> WKWebViewConfiguration
PROBE   websiteDataStore: persistent C6D35430-6C8D-41FA-BEB0-84D2F7959DDD
PROBE with the profile's store bound: contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier: -> WKWebViewConfiguration
PROBE   per-profile store factory asked for 6307052F-3F04-4DAE-83B9-FF20985FA8BA -> handed it non-persistent
PROBE   websiteDataStore is the bound one: true
PROBE step webconfig finished
2026-10-29 08:19:10.823 PrivacyBrowser[2323:11228] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:10.824 PrivacyBrowser[2323:11228] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:10.824 PrivacyBrowser[2323:11228] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:10.824 PrivacyBrowser[2323:11228] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:10.843 PrivacyBrowser[2323:11228] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:10.987 PrivacyBrowser[2323:11228] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:19:10.988 PrivacyBrowser[2323:11228] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
```

## shared — exited 0

```
PROBE step shared
PROBE macOS Version 15.7.9 (Build 24G830)
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
2026-10-29 08:19:11.014 PrivacyBrowser[2325:11242] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:11.016 PrivacyBrowser[2325:11242] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:11.016 PrivacyBrowser[2325:11242] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:11.016 PrivacyBrowser[2325:11242] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:11.026 PrivacyBrowser[2325:11242] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:11.027 PrivacyBrowser[2325:11242] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:19:11.027 PrivacyBrowser[2325:11242] SafariWindow: +sharedDocumentController is now BrowserDocumentController
```

## create-direct — killed by SIGTRAP

```
PROBE step create-direct
PROBE macOS Version 15.7.9 (Build 24G830)
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
2026-10-29 08:19:11.168 PrivacyBrowser[2326:11256] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:11.169 PrivacyBrowser[2326:11256] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:11.169 PrivacyBrowser[2326:11256] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:11.169 PrivacyBrowser[2326:11256] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:11.183 PrivacyBrowser[2326:11256] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:11.183 PrivacyBrowser[2326:11256] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:19:11.183 PrivacyBrowser[2326:11256] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:19:12.139 PrivacyBrowser[2326:11256] NSApplicationCrashOnExceptions=YES
```

Crash report `PrivacyBrowser-2026-10-29-081943.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:19:43.00 +0000",
    "app_version": "0.1.0",
    "slice_uuid": "23b4cf75-c396-3fba-82aa-140f63bdeab7",
    "build_version": "1",
    "platform": 1,
    "bundleID": "dev.local.PrivacyBrowser",
    "share_with_app_devs": 0,
    "is_first_party": 0,
    "bug_type": "309",
    "os_version": "macOS 15.7.9 (24G830)",
    "roots_installed": 0,
    "name": "PrivacyBrowser",
    "incident_id": "8CBCF712-F46D-4FCF-84B9-BAFEDC30ECAA"
  },
  "exception": {
    "codes": "0x0000000000000001, 0x0000000188209628",
    "rawCodes": [
      1,
      6578804264
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
    "byPid": 2326
  },
  "faultingThread": 0,
  "triggered_frames": [
    "AppKit + 3200552",
    "AppKit + 3199976",
    "AppKit + 187548",
    "PrivacyBrowser + 2008412",
    "PrivacyBrowser + 845960",
    "PrivacyBrowser + 846724",
    "PrivacyBrowser + 846724",
    "PrivacyBrowser + 846724",
    "PrivacyBrowser + 846724",
    "PrivacyBrowser + 845544",
    "dyld + 27544"
  ]
}
```

## create — exited 0

```
PROBE step create
PROBE macOS Version 15.7.9 (Build 24G830)
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
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x000000010411d498 PBPreprocessException + 52
PROBE     2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
PROBE     3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
PROBE     4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
PROBE     5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
PROBE     6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
PROBE     7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
PROBE     8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
PROBE     10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
PROBE     11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
PROBE     13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
PROBE     14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
PROBE     16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
PROBE     18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
PROBE     19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
PROBE     20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
PROBE     21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
PROBE     22  PrivacyBrowser                      0x0000000104236064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
PROBE     23  PrivacyBrowser                      0x000000010422a2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     24  PrivacyBrowser                      0x000000010422df08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     25  PrivacyBrowser                      0x00000001042326c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     26  PrivacyBrowser                      0x00000001040ce754 $sIeg_IeyB_TR + 28
PROBE     27  PrivacyBrowser                      0x000000010411d2f4 PBCatchException + 32
PROBE     28  PrivacyBrowser                      0x000000010422a068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     29  PrivacyBrowser                      0x00000001042274b4 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1384
PROBE     30  PrivacyBrowser                      0x000000010423b694 $s14PrivacyBrowser20SafariFrameworkProbeO10createStep33_9F0153DCAF2CE7EC9F01CEB735D44942LL9bootstrapySb_tFZ + 496
PROBE     31  PrivacyBrowser                      0x000000010423ab50 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TY0_ + 496
PROBE     32  PrivacyBrowser                      0x0000000104240d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     33  PrivacyBrowser                      0x00000001042ea7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     34  PrivacyBrowser                      0x00000001042ea815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     35  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
PROBE   -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
PROBE   giving up; the in-process web view path remains
PROBE window: nil
PROBE activation policy afterwards: 0 (0 = regular, 1 = accessory)
PROBE step create finished
2026-10-29 08:19:22.476 PrivacyBrowser[2433:11628] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:22.477 PrivacyBrowser[2433:11628] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:22.477 PrivacyBrowser[2433:11628] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:22.477 PrivacyBrowser[2433:11628] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:22.532 PrivacyBrowser[2433:11628] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:22.534 PrivacyBrowser[2433:11628] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:19:22.534 PrivacyBrowser[2433:11628] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:19:22.765 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:19:22.765 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]: document controller: BrowserDocumentController
2026-10-29 08:19:22.765 PrivacyBrowser[2433:11628] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:19:22.766 PrivacyBrowser[2433:11628] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:19:22.768 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]: BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
2026-10-29 08:19:22.770 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]: [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
2026-10-29 08:19:22.771 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]: window controller: BrowserWindowController
2026-10-29 08:19:22.992 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:19:22.992 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
2026-10-29 08:19:22.992 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   1   PrivacyBrowser                      0x000000010411d498 PBPreprocessException + 52
2026-10-29 08:19:22.992 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
2026-10-29 08:19:22.992 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:19:22.992 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:19:22.992 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
2026-10-29 08:19:22.992 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
2026-10-29 08:19:22.992 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
2026-10-29 08:19:22.992 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:22.992 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
2026-10-29 08:19:22.992 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:19:22.992 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:22.992 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:19:22.992 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:19:22.992 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   22  PrivacyBrowser                      0x0000000104236064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   23  PrivacyBrowser                      0x000000010422a2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   24  PrivacyBrowser                      0x000000010422df08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   25  PrivacyBrowser                      0x00000001042326c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   26  PrivacyBrowser                      0x00000001040ce754 $sIeg_IeyB_TR + 28
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   27  PrivacyBrowser                      0x000000010411d2f4 PBCatchException + 32
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   28  PrivacyBrowser                      0x000000010422a068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   29  PrivacyBrowser                      0x00000001042274b4 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1384
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   30  PrivacyBrowser                      0x000000010423b694 $s14PrivacyBrowser20SafariFrameworkProbeO10createStep33_9F0153DCAF2CE7EC9F01CEB735D44942LL9bootstrapySb_tFZ + 496
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   31  PrivacyBrowser                      0x000000010423ab50 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TY0_ + 496
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   32  PrivacyBrowser                      0x0000000104240d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   33  PrivacyBrowser                      0x00000001042ea7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   34  PrivacyBrowser                      0x00000001042ea815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
2026-10-29 08:19:22.993 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]:   35  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:19:22.995 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]: -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
2026-10-29 08:19:23.040 PrivacyBrowser[2433:11628] SafariWindow[6E4802B7]: giving up; the in-process web view path remains
```

## create-bootstrap — exited 0

```
PROBE step create-bootstrap
PROBE macOS Version 15.7.9 (Build 24G830)
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
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x000000010046d498 PBPreprocessException + 52
PROBE     2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
PROBE     3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
PROBE     4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
PROBE     5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
PROBE     6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
PROBE     7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
PROBE     8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
PROBE     10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
PROBE     11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
PROBE     13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
PROBE     14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
PROBE     16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
PROBE     18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
PROBE     19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
PROBE     20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
PROBE     21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
PROBE     22  PrivacyBrowser                      0x0000000100586064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
PROBE     23  PrivacyBrowser                      0x000000010057a2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     24  PrivacyBrowser                      0x000000010057df08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     25  PrivacyBrowser                      0x00000001005826c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     26  PrivacyBrowser                      0x000000010041e754 $sIeg_IeyB_TR + 28
PROBE     27  PrivacyBrowser                      0x000000010046d2f4 PBCatchException + 32
PROBE     28  PrivacyBrowser                      0x000000010057a068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     29  PrivacyBrowser                      0x00000001005774b4 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1384
PROBE     30  PrivacyBrowser                      0x000000010058b694 $s14PrivacyBrowser20SafariFrameworkProbeO10createStep33_9F0153DCAF2CE7EC9F01CEB735D44942LL9bootstrapySb_tFZ + 496
PROBE     31  PrivacyBrowser                      0x000000010058ab50 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TY0_ + 496
PROBE     32  PrivacyBrowser                      0x0000000100590d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     33  PrivacyBrowser                      0x000000010063a7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     34  PrivacyBrowser                      0x000000010063a815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     35  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
PROBE   -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
PROBE   giving up; the in-process web view path remains
PROBE window: nil
PROBE activation policy afterwards: 0 (0 = regular, 1 = accessory)
PROBE step create-bootstrap finished
2026-10-29 08:19:23.089 PrivacyBrowser[2435:11656] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:23.091 PrivacyBrowser[2435:11656] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:23.091 PrivacyBrowser[2435:11656] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:23.092 PrivacyBrowser[2435:11656] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:23.126 PrivacyBrowser[2435:11656] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:23.126 PrivacyBrowser[2435:11656] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:19:23.126 PrivacyBrowser[2435:11656] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:19:23.269 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:19:23.269 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]: document controller: BrowserDocumentController
2026-10-29 08:19:23.269 PrivacyBrowser[2435:11656] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:19:23.269 PrivacyBrowser[2435:11656] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:19:23.271 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]: BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
2026-10-29 08:19:23.273 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]: [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
2026-10-29 08:19:23.273 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]: window controller: BrowserWindowController
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   1   PrivacyBrowser                      0x000000010046d498 PBPreprocessException + 52
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:19:23.483 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
2026-10-29 08:19:23.484 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
2026-10-29 08:19:23.484 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   22  PrivacyBrowser                      0x0000000100586064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
2026-10-29 08:19:23.484 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   23  PrivacyBrowser                      0x000000010057a2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:19:23.484 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   24  PrivacyBrowser                      0x000000010057df08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:19:23.484 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   25  PrivacyBrowser                      0x00000001005826c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:19:23.484 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   26  PrivacyBrowser                      0x000000010041e754 $sIeg_IeyB_TR + 28
2026-10-29 08:19:23.484 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   27  PrivacyBrowser                      0x000000010046d2f4 PBCatchException + 32
2026-10-29 08:19:23.485 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   28  PrivacyBrowser                      0x000000010057a068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:19:23.485 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   29  PrivacyBrowser                      0x00000001005774b4 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1384
2026-10-29 08:19:23.485 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   30  PrivacyBrowser                      0x000000010058b694 $s14PrivacyBrowser20SafariFrameworkProbeO10createStep33_9F0153DCAF2CE7EC9F01CEB735D44942LL9bootstrapySb_tFZ + 496
2026-10-29 08:19:23.485 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   31  PrivacyBrowser                      0x000000010058ab50 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TY0_ + 496
2026-10-29 08:19:23.485 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   32  PrivacyBrowser                      0x0000000100590d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:19:23.485 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   33  PrivacyBrowser                      0x000000010063a7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:19:23.485 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   34  PrivacyBrowser                      0x000000010063a815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
2026-10-29 08:19:23.485 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]:   35  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:19:23.486 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]: -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
2026-10-29 08:19:23.492 PrivacyBrowser[2435:11656] SafariWindow[520DCA52]: giving up; the in-process web view path remains
```

## window — exited 0

```
PROBE step window
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads true; arguments YES, app 1, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads true; arguments YES, app 1, registered unset
PROBE profile store: persistent E77B69FD-5C35-41ED-85DC-01B875EC634C
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
PROBE   [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
PROBE   window controller: BrowserWindowController
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000102a75498 PBPreprocessException + 52
PROBE     2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
PROBE     3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
PROBE     4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
PROBE     5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
PROBE     6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
PROBE     7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
PROBE     8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
PROBE     10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
PROBE     11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
PROBE     13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
PROBE     14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
PROBE     16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
PROBE     18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
PROBE     19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
PROBE     20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
PROBE     21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
PROBE     22  PrivacyBrowser                      0x0000000102b8e064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
PROBE     23  PrivacyBrowser                      0x0000000102b822c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     24  PrivacyBrowser                      0x0000000102b85f08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     25  PrivacyBrowser                      0x0000000102b8a6c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     26  PrivacyBrowser                      0x0000000102a26754 $sIeg_IeyB_TR + 28
PROBE     27  PrivacyBrowser                      0x0000000102a752f4 PBCatchException + 32
PROBE     28  PrivacyBrowser                      0x0000000102b82068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     29  PrivacyBrowser                      0x0000000102b7f4b4 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1384
PROBE     30  PrivacyBrowser                      0x0000000102b94014 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZ04$s14a9Browser20cde17O10windowStep33_9ijklmno11LLyyYaFZSo8p10CSgAA0cB16qr6C_So18stU24C10Foundation3URLVtXEfU_Tf1cn_nTY0_ + 1104
PROBE     31  PrivacyBrowser                      0x0000000102b92e2d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ5_ + 1
PROBE     32  PrivacyBrowser                      0x0000000102b98d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     33  PrivacyBrowser                      0x0000000102c427c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     34  PrivacyBrowser                      0x0000000102c42815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     35  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
PROBE   -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
PROBE   giving up; the in-process web view path remains
PROBE RESULT no window
PROBE activation policy afterwards: 0 (0 = regular, 1 = accessory)
PROBE FALLBACK in-process window: visible=true url=https://example.com/ title=Example Domain
PROBE wrote fallback-window.png (15340 bytes)
PROBE wrote fallback-page.png (76051 bytes)
PROBE step window finished
2026-10-29 08:19:23.549 PrivacyBrowser[2436:11681] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:23.550 PrivacyBrowser[2436:11681] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:23.550 PrivacyBrowser[2436:11681] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:23.550 PrivacyBrowser[2436:11681] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:23.567 PrivacyBrowser[2436:11681] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:23.568 PrivacyBrowser[2436:11681] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:19:23.568 PrivacyBrowser[2436:11681] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:19:23.706 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:19:23.707 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]: document controller: BrowserDocumentController
2026-10-29 08:19:23.707 PrivacyBrowser[2436:11681] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:19:23.707 PrivacyBrowser[2436:11681] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:19:23.709 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]: BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
2026-10-29 08:19:23.710 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]: [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
2026-10-29 08:19:23.710 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]: window controller: BrowserWindowController
2026-10-29 08:19:23.956 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:19:23.956 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
2026-10-29 08:19:23.956 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   1   PrivacyBrowser                      0x0000000102a75498 PBPreprocessException + 52
2026-10-29 08:19:23.956 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
2026-10-29 08:19:23.956 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   22  PrivacyBrowser                      0x0000000102b8e064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   23  PrivacyBrowser                      0x0000000102b822c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   24  PrivacyBrowser                      0x0000000102b85f08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   25  PrivacyBrowser                      0x0000000102b8a6c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   26  PrivacyBrowser                      0x0000000102a26754 $sIeg_IeyB_TR + 28
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   27  PrivacyBrowser                      0x0000000102a752f4 PBCatchException + 32
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   28  PrivacyBrowser                      0x0000000102b82068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   29  PrivacyBrowser                      0x0000000102b7f4b4 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1384
2026-10-29 08:19:23.957 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   30  PrivacyBrowser                      0x0000000102b94014 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZ04$s14a9Browser20cde17O10windowStep33_9ijklmno11LLyyYaFZSo8p10CSgAA0cB16qr6C_So18stU24C10Foundation3URLVtXEfU_Tf1cn_nTY0_ + 1104
2026-10-29 08:19:23.958 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   31  PrivacyBrowser                      0x0000000102b92e2d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ5_ + 1
2026-10-29 08:19:23.958 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   32  PrivacyBrowser                      0x0000000102b98d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:19:23.958 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   33  PrivacyBrowser                      0x0000000102c427c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:19:23.958 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   34  PrivacyBrowser                      0x0000000102c42815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
2026-10-29 08:19:23.958 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]:   35  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:19:23.958 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]: -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
2026-10-29 08:19:23.962 PrivacyBrowser[2436:11681] SafariWindow[E77B69FD]: giving up; the in-process web view path remains
```

## popupfield — exited 0

```
PROBE step popupfield
PROBE macOS Version 15.7.9 (Build 24G830)
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
PROBE   1244 instance methods, 10 class methods, 296 ivars, 322 properties
PROBE   *init*: _abortInitiateLoad, _commonInitializationWithDocument:, _didStartBrowserInitiatedLoadUsingBackForwardList:, _hideTransientBannerDueToUserInitiatedNavigationOrVisuallyNonEmptyLayout, _initializeScribbleOut, _initiateLoad, _initiateQueuedNavigation, _tryToInitiateLoad:initiateLoadBlock:, alwaysInitiateLoadsInContinuousModeUsingCurrentController, clearPendingBrowserInitiatedLoad, didCollectMetadataForPrefillingFormInFrames:metadataForAllForms:isInitialCollectionAtPageLoad:, displayInitialContents, initWithDefaultWebViewConfigurationWithDocument:browsingMode:, initWithDocument:configuration:browsingMode:
PROBE   *window*: _addDomainToAllowedPopUpWindowDomainCache:, _selectTabViewItem:inWindowController:cancelIfInvalid:, _simulateKeysToTypeTextInToBrowserView:textToType:characterIndex:windowNumber:shouldSendReturnKeyEvent:, _updateWKViewLayoutModeForWindow:, _windowCanBeResized:, _windowPolicyForCreateBrowserViewController, addBlockedPopUpWindowConfiguration:, announceIfLinkOpenedInNewTabOrWindowWithVoiceOverLinkPolicy:, announceIfLinkOpenedInNewTabOrWindowWithWindowPolicy:, bringTabAndWindowToFront, bringTabAndWindowToFrontForUserNotification:, browserViewDidMoveToWindow, browserViewWillMoveToWindow:, browserWKViewDidMoveToNewWindow
PROBE   *profile*: isWaitingForBytecodeProfile, isWaitingForSamplingProfilerOutput, profile, setWaitingForBytecodeProfile:, setWaitingForSamplingProfilerOutput:
PROBE   *webview*: _createWebViewWithConfiguration:, _handleCertificateError:forWebView:isMainFrame:, _handleErrorForWebView:isMainFrame:pageLoadType:error:getIsTryingFallbackURLs:, _installAlternativeWebViewFunctionBarProvider:, _installWebView, _startObservingWKWebViewKeyValueChanges, _stopObservingWKWebViewKeyValueChanges, _uninstallAlternativeWebViewFunctionBarProvider, _webView:storeAppHighlight:inNewGroup:requestOriginatedInApp:, createContentViewController, initWithDefaultWebViewConfigurationWithDocument:browsingMode:, isShowingWebView, locationChangeDoneForWebView:isMainFrame:pageLoadType:error:, readerWebViewDidScroll
PROBE   *configuration*: _createWebViewWithConfiguration:, addBlockedPopUpWindowConfiguration:, assistantReaderCardConfigurationManager, clearBlockedWindowConfigurationCaches, createBrowserViewControllerFromWindowConfiguration:, duplicateUsingConfiguration:forWebExtensionContext:completionHandler:, initWithDefaultWebViewConfigurationWithDocument:browsingMode:, initWithDocument:configuration:browsingMode:, openWindowWithConfiguration:, presentTabDialogWithConfiguration:dismissalBlock:blocksWebProcessUntilDismissed:cancellationExemptions:, readerConfigurationChanged, setAssistantReaderCardConfigurationManager:
PROBE   *new*: _createNewExtensionBannerIfNecessary, _loadURLRequest:tabLabel:lifetime:allowJavaScript:waitInQueue:clearFallbackURLs:inNewProcess:skipSyncableTabUpdates:canAttemptUpgradingRequestURLToHTTPS:, _webView:storeAppHighlight:inNewGroup:requestOriginatedInApp:, addNavigationNeedingNewProcess:, announceIfLinkOpenedInNewTabOrWindowWithVoiceOverLinkPolicy:, announceIfLinkOpenedInNewTabOrWindowWithWindowPolicy:, browserWKViewDidMoveToNewWindow, didSaveNewSavedAccountWithGeneratedPassword:, fireReplacedEventToExtensionsIfNecessaryWithNewBrowserViewController:, hideNewExtensionBannerAnimated:, loadURL:tabLabel:httpReferrer:inNewProcess:canAttemptUpgradingRequestURLToHTTPS:, loadURL:tabLabel:httpReferrer:inNewProcess:canAttemptUpgradingRequestURLToHTTPS:additionalHeaderFields:, loadURLRequest:tabLabel:inNewProcess:canAttemptUpgradingRequestURLToHTTPS:, loadURLRequest:tabLabel:lifetime:allowJavaScript:waitInQueue:inNewProcess:canAttemptUpgradingRequestURLToHTTPS:
PROBE   *tab*: _addSpawnedTabBrowserViewController:, _canPersistTabs, _defaultDatabaseQuota, _didDismissTabDialogs, _enqueueRestoredNavigation:withTabState:, _isAutoSelectableWithURL:, _isOnlyTabInWebProcessThatIsShowingWebContent, _loadURLRequest:tabLabel:lifetime:allowJavaScript:waitInQueue:clearFallbackURLs:inNewProcess:skipSyncableTabUpdates:canAttemptUpgradingRequestURLToHTTPS:, _pageMutableMediaState, _removeSpawnedTabBrowserViewController:, _removeTabFromCoreSpotlight, _restoreTabIdentifiersWithPersistentTabState:, _returnToParentTabAndOptionallyCloseTab:, _selectTabViewItem:inWindowController:cancelIfInvalid:
PROBE   ivars naming a store or a profile: _contentBlockerStatisticsStore  @"<WBSContentBlockerStatisticsStore>" | _profileIdentifierForExtensions  @"NSString" | _waitingForSamplingProfilerOutput  B | _waitingForBytecodeProfile  B | _pendingTabStateToRestore  @"BrowserTabPersistentState" | _sessionStateToRestoreAfterFinishingNavigation  {SessionState="m_webKit2Object"{WKRetainPtr<const void *>="m_ptr"^v}}
PROBE wrote framework-PopupWindowUnifiedField.txt (99561 bytes)
PROBE step popupfield finished
2026-10-29 08:19:25.783 PrivacyBrowser[2447:11824] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:25.784 PrivacyBrowser[2447:11824] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:25.784 PrivacyBrowser[2447:11824] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:25.784 PrivacyBrowser[2447:11824] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:25.808 PrivacyBrowser[2447:11824] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## popup — exited 0

```
PROBE step popup
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments unset, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments unset, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments unset, app unset, registered unset
PROBE profile store: persistent B0B95040-94C5-4B79-8113-3E7C45ABC60C
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup
PROBE   NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
PROBE   [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x000000010266d498 PBPreprocessException + 52
PROBE     2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
PROBE     3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
PROBE     4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
PROBE     5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
PROBE     6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
PROBE     7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
PROBE     8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
PROBE     10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
PROBE     11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
PROBE     13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
PROBE     14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
PROBE     16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
PROBE     18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
PROBE     19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
PROBE     20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
PROBE     21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
PROBE     22  PrivacyBrowser                      0x0000000102786064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
PROBE     23  PrivacyBrowser                      0x000000010277a2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     24  PrivacyBrowser                      0x000000010277df08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     25  PrivacyBrowser                      0x00000001027826c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     26  PrivacyBrowser                      0x000000010261e754 $sIeg_IeyB_TR + 28
PROBE     27  PrivacyBrowser                      0x000000010266d2f4 PBCatchException + 32
PROBE     28  PrivacyBrowser                      0x000000010277a068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     29  PrivacyBrowser                      0x000000010277c5b4 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3860
PROBE     30  PrivacyBrowser                      0x0000000102778c90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
PROBE     31  PrivacyBrowser                      0x0000000102790180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
PROBE     32  PrivacyBrowser                      0x000000010278e344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
PROBE     33  PrivacyBrowser                      0x000000010278ac99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     34  PrivacyBrowser                      0x0000000102790d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     35  PrivacyBrowser                      0x000000010283a7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     36  PrivacyBrowser                      0x000000010283a815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     37  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
PROBE   -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
PROBE   popup path, popup: giving up — raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE   view tree: NSThemeFrame[NSVisualEffectView NSView[NSView[NSView[NSView[NSSplitView[… … … … …]]]]] NSTitlebarContainerView[_NSTitlebarDecorationView NSTitlebarView[NSVisualEffectView NSView _NSThemeCloseWidget _NSThemeZoomWidget _NSThemeWidget NSTextField NSToolbarView]]]
PROBE   UnifiedField views in the window: 0
PROBE   toolbar: BrowserToolbar, visible true; title bar accessories: none
PROBE   -unifiedField -> UnifiedField, superview UnifiedFieldContainerView, in a window false, hidden false, frame {{0, 0}, {343, 28}}
PROBE   _popupWindowUnifiedField -> nil
PROBE   the profile's store was handed out 0 times during the attempt
PROBE RESULT no window
PROBE activation policy afterwards: 0 (0 = regular, 1 = accessory)
PROBE FALLBACK in-process window: visible=true url=https://example.com/ title=Example Domain
PROBE wrote fallback-window.png (15340 bytes)
PROBE wrote fallback-page.png (76051 bytes)
PROBE step popup finished
2026-10-29 08:19:25.953 PrivacyBrowser[2448:11829] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:25.954 PrivacyBrowser[2448:11829] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:25.954 PrivacyBrowser[2448:11829] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:25.954 PrivacyBrowser[2448:11829] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:25.969 PrivacyBrowser[2448:11829] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:25.970 PrivacyBrowser[2448:11829] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:19:25.970 PrivacyBrowser[2448:11829] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:19:26.099 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:19:26.099 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]: document controller: BrowserDocumentController
2026-10-29 08:19:26.099 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]: popup path, popup
2026-10-29 08:19:26.099 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]: NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
2026-10-29 08:19:26.099 PrivacyBrowser[2448:11829] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:19:26.099 PrivacyBrowser[2448:11829] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:19:26.102 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]: [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
2026-10-29 08:19:26.102 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:19:26.102 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   1   PrivacyBrowser                      0x000000010266d498 PBPreprocessException + 52
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:19:26.318 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   22  PrivacyBrowser                      0x0000000102786064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   23  PrivacyBrowser                      0x000000010277a2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   24  PrivacyBrowser                      0x000000010277df08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   25  PrivacyBrowser                      0x00000001027826c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   26  PrivacyBrowser                      0x000000010261e754 $sIeg_IeyB_TR + 28
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   27  PrivacyBrowser                      0x000000010266d2f4 PBCatchException + 32
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   28  PrivacyBrowser                      0x000000010277a068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   29  PrivacyBrowser                      0x000000010277c5b4 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3860
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   30  PrivacyBrowser                      0x0000000102778c90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   31  PrivacyBrowser                      0x0000000102790180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   32  PrivacyBrowser                      0x000000010278e344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   33  PrivacyBrowser                      0x000000010278ac99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   34  PrivacyBrowser                      0x0000000102790d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariWindow[B0B95040]:   35  PrivacyBrowser                      0x000000010283a7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:19:26.319 PrivacyBrowser[2448:11829] SafariW
```

## popup-nofield — exited 0

```
PROBE step popup-nofield
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments unset, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments unset, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments unset, app unset, registered unset
PROBE profile store: persistent 4DE468BC-BD6B-4EF7-ABA5-C1ACA34EBBF1
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup-nofield
PROBE   NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
PROBE   [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   setPopupWindowUnifiedFieldVisible:NO -> sent; isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000102d95498 PBPreprocessException + 52
PROBE     2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
PROBE     3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
PROBE     4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
PROBE     5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
PROBE     6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
PROBE     7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
PROBE     8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
PROBE     10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
PROBE     11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
PROBE     13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
PROBE     14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
PROBE     16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
PROBE     18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
PROBE     19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
PROBE     20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
PROBE     21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
PROBE     22  PrivacyBrowser                      0x0000000102eae064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
PROBE     23  PrivacyBrowser                      0x0000000102ea22c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     24  PrivacyBrowser                      0x0000000102ea5f08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     25  PrivacyBrowser                      0x0000000102eaa6c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     26  PrivacyBrowser                      0x0000000102d46754 $sIeg_IeyB_TR + 28
PROBE     27  PrivacyBrowser                      0x0000000102d952f4 PBCatchException + 32
PROBE     28  PrivacyBrowser                      0x0000000102ea2068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     29  PrivacyBrowser                      0x0000000102ea45b4 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3860
PROBE     30  PrivacyBrowser                      0x0000000102ea0c90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
PROBE     31  PrivacyBrowser                      0x0000000102eb8180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
PROBE     32  PrivacyBrowser                      0x0000000102eb6344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
PROBE     33  PrivacyBrowser                      0x0000000102eb2c99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     34  PrivacyBrowser                      0x0000000102eb8d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     35  PrivacyBrowser                      0x0000000102f627c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     36  PrivacyBrowser                      0x0000000102f62815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     37  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
PROBE   -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
PROBE   popup path, popup-nofield: giving up — raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE   view tree: NSThemeFrame[NSVisualEffectView NSView[NSView[NSView[NSView[NSSplitView[… … … … …]]]]] NSTitlebarContainerView[_NSTitlebarDecorationView NSTitlebarView[NSVisualEffectView NSView _NSThemeCloseWidget _NSThemeZoomWidget _NSThemeWidget NSTextField NSToolbarView]]]
PROBE   UnifiedField views in the window: 0
PROBE   toolbar: BrowserToolbar, visible true; title bar accessories: none
PROBE   -unifiedField -> UnifiedField, superview UnifiedFieldContainerView, in a window false, hidden false, frame {{0, 0}, {343, 28}}
PROBE   _popupWindowUnifiedField -> nil
PROBE   the profile's store was handed out 0 times during the attempt
PROBE RESULT no window
PROBE activation policy afterwards: 0 (0 = regular, 1 = accessory)
PROBE FALLBACK in-process window: visible=true url=https://example.com/ title=Example Domain
PROBE wrote fallback-window.png (15340 bytes)
PROBE wrote fallback-page.png (76051 bytes)
PROBE step popup-nofield finished
2026-10-29 08:19:28.311 PrivacyBrowser[2550:12190] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:28.311 PrivacyBrowser[2550:12190] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:28.311 PrivacyBrowser[2550:12190] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:28.311 PrivacyBrowser[2550:12190] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:28.322 PrivacyBrowser[2550:12190] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:28.323 PrivacyBrowser[2550:12190] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:19:28.323 PrivacyBrowser[2550:12190] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:19:28.420 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:19:28.420 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]: document controller: BrowserDocumentController
2026-10-29 08:19:28.420 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]: popup path, popup-nofield
2026-10-29 08:19:28.420 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]: NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
2026-10-29 08:19:28.421 PrivacyBrowser[2550:12190] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:19:28.421 PrivacyBrowser[2550:12190] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:19:28.422 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]: [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
2026-10-29 08:19:28.422 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:19:28.422 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:19:28.422 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]: setPopupWindowUnifiedFieldVisible:NO -> sent; isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   1   PrivacyBrowser                      0x0000000102d95498 PBPreprocessException + 52
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   22  PrivacyBrowser                      0x0000000102eae064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   23  PrivacyBrowser                      0x0000000102ea22c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   24  PrivacyBrowser                      0x0000000102ea5f08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   25  PrivacyBrowser                      0x0000000102eaa6c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   26  PrivacyBrowser                      0x0000000102d46754 $sIeg_IeyB_TR + 28
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   27  PrivacyBrowser                      0x0000000102d952f4 PBCatchException + 32
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   28  PrivacyBrowser                      0x0000000102ea2068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   29  PrivacyBrowser                      0x0000000102ea45b4 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3860
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   30  PrivacyBrowser                      0x0000000102ea0c90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   31  PrivacyBrowser                      0x0000000102eb8180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   32  PrivacyBrowser                      0x0000000102eb6344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   33  PrivacyBrowser                      0x0000000102eb2c99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:19:28.613 PrivacyBrowser[2550:12190] SafariWindow[4DE468BC]:   34  PrivacyBrowser                      0x0000000102eb8d69 $s14PrivacyBrowse
```

## popup-mode — exited 0

```
PROBE step popup-mode
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments unset, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments unset, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments unset, app unset, registered unset
PROBE profile store: persistent 06457C71-6360-4397-8FD6-18DD6172ACFB
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup-mode
PROBE   NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
PROBE   [[BrowserWindowController alloc] initWithBrowsingMode:0 isPopupWindow:YES]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x000000010218d498 PBPreprocessException + 52
PROBE     2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
PROBE     3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
PROBE     4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
PROBE     5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
PROBE     6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
PROBE     7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
PROBE     8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
PROBE     10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
PROBE     11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
PROBE     13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
PROBE     14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
PROBE     16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
PROBE     18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
PROBE     19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
PROBE     20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
PROBE     21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
PROBE     22  PrivacyBrowser                      0x00000001022a6064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
PROBE     23  PrivacyBrowser                      0x000000010229a2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     24  PrivacyBrowser                      0x000000010229df08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     25  PrivacyBrowser                      0x00000001022a26c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     26  PrivacyBrowser                      0x000000010213e754 $sIeg_IeyB_TR + 28
PROBE     27  PrivacyBrowser                      0x000000010218d2f4 PBCatchException + 32
PROBE     28  PrivacyBrowser                      0x000000010229a068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     29  PrivacyBrowser                      0x000000010229c5b4 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3860
PROBE     30  PrivacyBrowser                      0x0000000102298c90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
PROBE     31  PrivacyBrowser                      0x00000001022b0180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
PROBE     32  PrivacyBrowser                      0x00000001022ae344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
PROBE     33  PrivacyBrowser                      0x00000001022aac99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     34  PrivacyBrowser                      0x00000001022b0d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     35  PrivacyBrowser                      0x000000010235a7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     36  PrivacyBrowser                      0x000000010235a815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     37  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
PROBE   -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
PROBE   popup path, popup-mode: giving up — raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE   view tree: NSThemeFrame[NSVisualEffectView NSView[NSView[NSView[NSView[NSSplitView[… … … … …]]]]] NSTitlebarContainerView[_NSTitlebarDecorationView NSTitlebarView[NSVisualEffectView NSView _NSThemeCloseWidget _NSThemeZoomWidget _NSThemeWidget NSTextField NSToolbarView]]]
PROBE   UnifiedField views in the window: 0
PROBE   toolbar: BrowserToolbar, visible true; title bar accessories: none
PROBE   -unifiedField -> UnifiedField, superview UnifiedFieldContainerView, in a window false, hidden false, frame {{0, 0}, {343, 28}}
PROBE   _popupWindowUnifiedField -> nil
PROBE   the profile's store was handed out 0 times during the attempt
PROBE RESULT no window
PROBE activation policy afterwards: 0 (0 = regular, 1 = accessory)
PROBE FALLBACK in-process window: visible=true url=https://example.com/ title=Example Domain
PROBE wrote fallback-window.png (15340 bytes)
PROBE wrote fallback-page.png (76051 bytes)
PROBE step popup-mode finished
2026-10-29 08:19:30.350 PrivacyBrowser[2557:12303] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:30.351 PrivacyBrowser[2557:12303] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:30.351 PrivacyBrowser[2557:12303] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:30.351 PrivacyBrowser[2557:12303] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:30.361 PrivacyBrowser[2557:12303] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:30.361 PrivacyBrowser[2557:12303] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:19:30.361 PrivacyBrowser[2557:12303] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:19:30.452 PrivacyBrowser[2557:12303] SafariWindow[06457C71]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:19:30.452 PrivacyBrowser[2557:12303] SafariWindow[06457C71]: document controller: BrowserDocumentController
2026-10-29 08:19:30.452 PrivacyBrowser[2557:12303] SafariWindow[06457C71]: popup path, popup-mode
2026-10-29 08:19:30.452 PrivacyBrowser[2557:12303] SafariWindow[06457C71]: NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
2026-10-29 08:19:30.453 PrivacyBrowser[2557:12303] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:19:30.453 PrivacyBrowser[2557:12303] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:19:30.457 PrivacyBrowser[2557:12303] SafariWindow[06457C71]: [[BrowserWindowController alloc] initWithBrowsingMode:0 isPopupWindow:YES]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
2026-10-29 08:19:30.457 PrivacyBrowser[2557:12303] SafariWindow[06457C71]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:19:30.457 PrivacyBrowser[2557:12303] SafariWindow[06457C71]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:19:30.602 PrivacyBrowser[2557:12303] SafariWindow[06457C71]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:19:30.602 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
2026-10-29 08:19:30.602 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   1   PrivacyBrowser                      0x000000010218d498 PBPreprocessException + 52
2026-10-29 08:19:30.602 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   22  PrivacyBrowser                      0x00000001022a6064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   23  PrivacyBrowser                      0x000000010229a2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   24  PrivacyBrowser                      0x000000010229df08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   25  PrivacyBrowser                      0x00000001022a26c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   26  PrivacyBrowser                      0x000000010213e754 $sIeg_IeyB_TR + 28
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   27  PrivacyBrowser                      0x000000010218d2f4 PBCatchException + 32
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   28  PrivacyBrowser                      0x000000010229a068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   29  PrivacyBrowser                      0x000000010229c5b4 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3860
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   30  PrivacyBrowser                      0x0000000102298c90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   31  PrivacyBrowser                      0x00000001022b0180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   32  PrivacyBrowser                      0x00000001022ae344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   33  PrivacyBrowser                      0x00000001022aac99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   34  PrivacyBrowser                      0x00000001022b0d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:19:30.603 PrivacyBrowser[2557:12303] SafariWindow[06457C71]:   35  PrivacyBrowser                      0x000000010235a7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8Sen
```

## popup-hidden — exited 0

```
PROBE step popup-hidden
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments unset, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments unset, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments unset, app unset, registered unset
PROBE profile store: persistent FEE4CC85-43F5-4FEB-8E6F-D603797384FC
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup-hidden
PROBE   NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
PROBE   RAISED NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x12f60da60
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000102e11498 PBPreprocessException + 52
PROBE     2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
PROBE     3   CoreFoundation                      0x0000000184144800 -[NSObject(NSObject) __retain_OA] + 0
PROBE     4   CoreFoundation                      0x0000000183ff59dc ___forwarding___ + 1500
PROBE     5   CoreFoundation                      0x0000000183ff5340 _CF_forwarding_prep_0 + 96
PROBE     6   Safari                              0x00000001b688f7b0 -[BrowserDocument makeWindowControllers] + 168
PROBE     7   Safari                              0x00000001b689b58c -[BrowserDocumentController _createBrowserDocumentWithBrowsingMode:profileIdentifier:configuration:initialSize:options:] + 144
PROBE     8   Safari                              0x00000001b689b47c -[BrowserDocumentController _createBrowserDocumentWithBrowsingMode:profileIdentifier:initialSize:options:] + 232
PROBE     9   Safari                              0x00000001b6897350 -[BrowserDocumentController createHiddenEmptyBrowserDocumentWithBrowsingMode:profileIdentifier:jitEnabled:isPopupWindow:restoringFromLastSession:initialSize:] + 64
PROBE     10  Safari                              0x00000001b6989a98 +[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:restoringFromLastSession:] + 108
PROBE     11  Safari                              0x00000001b6989b3c +[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:] + 20
PROBE     12  PrivacyBrowser                      0x0000000102f2d214 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObject__7integer6object4flagSo8NSObjectCSg5value_SS6reasontyXl_SSSiyXlSgSbtFZTf4nnnnnd_n + 140
PROBE     13  PrivacyBrowser                      0x0000000102f21d9c $s14PrivacyBrowser06SafariB16WindowControllerC011createPopupE033_D5663EB8AEBCFB374BED3A50E441DB28LL_2ofSo8NSObjectCSgAC0G7VariantO_yXlXptF + 384
PROBE     14  PrivacyBrowser                      0x0000000102f21be8 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU_ + 36
PROBE     15  PrivacyBrowser                      0x0000000102dc2754 $sIeg_IeyB_TR + 28
PROBE     16  PrivacyBrowser                      0x0000000102e112f4 PBCatchException + 32
PROBE     17  PrivacyBrowser                      0x0000000102f1e068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     18  PrivacyBrowser                      0x0000000102f1f7a0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 256
PROBE     19  PrivacyBrowser                      0x0000000102f1cc90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
PROBE     20  PrivacyBrowser                      0x0000000102f34180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
PROBE     21  PrivacyBrowser                      0x0000000102f32344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
PROBE     22  PrivacyBrowser                      0x0000000102f2ec99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     23  PrivacyBrowser                      0x0000000102f34d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     24  PrivacyBrowser                      0x0000000102fde7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     25  PrivacyBrowser                      0x0000000102fde815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     26  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
PROBE   creating the controller raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x12f60da60; caught, so the attempt ends and the process does not
PROBE   popup path, popup-hidden: giving up — raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x12f60da60
PROBE   the profile's store was handed out 3 times during the attempt
PROBE     per-profile store factory asked for FEE4CC85-43F5-4FEB-8E6F-D603797384FC -> handed it persistent FEE4CC85-43F5-4FEB-8E6F-D603797384FC
PROBE     per-profile store factory asked for FEE4CC85-43F5-4FEB-8E6F-D603797384FC -> handed it persistent FEE4CC85-43F5-4FEB-8E6F-D603797384FC
PROBE     websiteDataStore read on WKWebViewConfiguration -> persistent FEE4CC85-43F5-4FEB-8E6F-D603797384FC
PROBE RESULT no window
PROBE activation policy afterwards: 0 (0 = regular, 1 = accessory)
PROBE FALLBACK in-process window: visible=true url=https://example.com/ title=Example Domain
PROBE wrote fallback-window.png (15340 bytes)
PROBE wrote fallback-page.png (76051 bytes)
PROBE step popup-hidden finished
2026-10-29 08:19:32.298 PrivacyBrowser[2563:12400] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:32.298 PrivacyBrowser[2563:12400] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:32.299 PrivacyBrowser[2563:12400] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:32.299 PrivacyBrowser[2563:12400] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:32.307 PrivacyBrowser[2563:12400] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:32.307 PrivacyBrowser[2563:12400] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:19:32.307 PrivacyBrowser[2563:12400] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:19:32.401 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:19:32.401 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]: document controller: BrowserDocumentController
2026-10-29 08:19:32.401 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]: popup path, popup-hidden
2026-10-29 08:19:32.401 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]: NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
2026-10-29 08:19:32.401 PrivacyBrowser[2563:12400] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:19:32.401 PrivacyBrowser[2563:12400] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:19:32.431 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]: RAISED NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x12f60da60
2026-10-29 08:19:32.431 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
2026-10-29 08:19:32.431 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   1   PrivacyBrowser                      0x0000000102e11498 PBPreprocessException + 52
2026-10-29 08:19:32.431 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
2026-10-29 08:19:32.431 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   3   CoreFoundation                      0x0000000184144800 -[NSObject(NSObject) __retain_OA] + 0
2026-10-29 08:19:32.431 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   4   CoreFoundation                      0x0000000183ff59dc ___forwarding___ + 1500
2026-10-29 08:19:32.431 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   5   CoreFoundation                      0x0000000183ff5340 _CF_forwarding_prep_0 + 96
2026-10-29 08:19:32.431 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   6   Safari                              0x00000001b688f7b0 -[BrowserDocument makeWindowControllers] + 168
2026-10-29 08:19:32.431 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   7   Safari                              0x00000001b689b58c -[BrowserDocumentController _createBrowserDocumentWithBrowsingMode:profileIdentifier:configuration:initialSize:options:] + 144
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   8   Safari                              0x00000001b689b47c -[BrowserDocumentController _createBrowserDocumentWithBrowsingMode:profileIdentifier:initialSize:options:] + 232
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   9   Safari                              0x00000001b6897350 -[BrowserDocumentController createHiddenEmptyBrowserDocumentWithBrowsingMode:profileIdentifier:jitEnabled:isPopupWindow:restoringFromLastSession:initialSize:] + 64
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   10  Safari                              0x00000001b6989a98 +[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:restoringFromLastSession:] + 108
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   11  Safari                              0x00000001b6989b3c +[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:] + 20
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   12  PrivacyBrowser                      0x0000000102f2d214 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObject__7integer6object4flagSo8NSObjectCSg5value_SS6reasontyXl_SSSiyXlSgSbtFZTf4nnnnnd_n + 140
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   13  PrivacyBrowser                      0x0000000102f21d9c $s14PrivacyBrowser06SafariB16WindowControllerC011createPopupE033_D5663EB8AEBCFB374BED3A50E441DB28LL_2ofSo8NSObjectCSgAC0G7VariantO_yXlXptF + 384
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   14  PrivacyBrowser                      0x0000000102f21be8 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU_ + 36
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   15  PrivacyBrowser                      0x0000000102dc2754 $sIeg_IeyB_TR + 28
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   16  PrivacyBrowser                      0x0000000102e112f4 PBCatchException + 32
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   17  PrivacyBrowser                      0x0000000102f1e068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   18  PrivacyBrowser                      0x0000000102f1f7a0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 256
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   19  PrivacyBrowser                      0x0000000102f1cc90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   20  PrivacyBrowser                      0x0000000102f34180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   21  PrivacyBrowser                      0x0000000102f32344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   22  PrivacyBrowser                      0x0000000102f2ec99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   23  PrivacyBrowser                      0x0000000102f34d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   24  PrivacyBrowser                      0x0000000102fde7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:19:32.432 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   25  PrivacyBrowser                      0x0000000102fde815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
2026-10-29 08:19:32.433 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   26  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:19:32.434 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]: creating the controller raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x12f60da60; caught, so the attempt ends and the process does not
2026-10-29 08:19:32.434 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]: popup path, popup-hidden: giving up — raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x12f60da60
2026-10-29 08:19:32.434 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]: the profile's store was handed out 3 times during the attempt
2026-10-29 08:19:32.434 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   per-profile store factory asked for FEE4CC85-43F5-4FEB-8E6F-D603797384FC -> handed it persistent FEE4CC85-43F5-4FEB-8E6F-D603797384FC
2026-10-29 08:19:32.434 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   per-profile store factory asked for FEE4CC85-43F5-4FEB-8E6F-D603797384FC -> handed it persistent FEE4CC85-43F5-4FEB-8E6F-D603797384FC
2026-10-29 08:19:32.434 PrivacyBrowser[2563:12400] SafariWindow[FEE4CC85]:   websiteDataStore read on WKWebViewConfiguration -> persistent FEE4CC85-43F5-4FEB-8E6F-D603797384FC
```

## popup:crash-off — exited 0

```
PROBE step popup
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments NO, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments NO, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments NO, app unset, registered unset
PROBE profile store: persistent 69087470-EC77-4D8C-8D7F-3366416EB390
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup
PROBE   NSApplicationCrashOnExceptions: reads false; arguments NO, app unset, registered unset
PROBE   [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x000000010265d498 PBPreprocessException + 52
PROBE     2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
PROBE     3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
PROBE     4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
PROBE     5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
PROBE     6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
PROBE     7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
PROBE     8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
PROBE     10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
PROBE     11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
PROBE     13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
PROBE     14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
PROBE     16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
PROBE     18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
PROBE     19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
PROBE     20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
PROBE     21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
PROBE     22  PrivacyBrowser                      0x0000000102776064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
PROBE     23  PrivacyBrowser                      0x000000010276a2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     24  PrivacyBrowser                      0x000000010276df08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     25  PrivacyBrowser                      0x00000001027726c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     26  PrivacyBrowser                      0x000000010260e754 $sIeg_IeyB_TR + 28
PROBE     27  PrivacyBrowser                      0x000000010265d2f4 PBCatchException + 32
PROBE     28  PrivacyBrowser                      0x000000010276a068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     29  PrivacyBrowser                      0x000000010276c5b4 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3860
PROBE     30  PrivacyBrowser                      0x0000000102768c90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
PROBE     31  PrivacyBrowser                      0x0000000102780180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
PROBE     32  PrivacyBrowser                      0x000000010277e344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
PROBE     33  PrivacyBrowser                      0x000000010277ac99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     34  PrivacyBrowser                      0x0000000102780d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     35  PrivacyBrowser                      0x000000010282a7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     36  PrivacyBrowser                      0x000000010282a815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     37  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
PROBE   -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
PROBE   popup path, popup: giving up — raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE   view tree: NSThemeFrame[NSVisualEffectView NSView[NSView[NSView[NSView[NSSplitView[… … … … …]]]]] NSTitlebarContainerView[_NSTitlebarDecorationView NSTitlebarView[NSVisualEffectView NSView _NSThemeCloseWidget _NSThemeZoomWidget _NSThemeWidget NSTextField NSToolbarView]]]
PROBE   UnifiedField views in the window: 0
PROBE   toolbar: BrowserToolbar, visible true; title bar accessories: none
PROBE   -unifiedField -> UnifiedField, superview UnifiedFieldContainerView, in a window false, hidden false, frame {{0, 0}, {343, 28}}
PROBE   _popupWindowUnifiedField -> nil
PROBE   the profile's store was handed out 0 times during the attempt
PROBE RESULT no window
PROBE activation policy afterwards: 0 (0 = regular, 1 = accessory)
PROBE FALLBACK in-process window: visible=true url=https://example.com/ title=Example Domain
PROBE wrote fallback-window.png (15340 bytes)
PROBE wrote fallback-page.png (76051 bytes)
PROBE step popup finished
2026-10-29 08:19:34.123 PrivacyBrowser[2568:12489] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:34.123 PrivacyBrowser[2568:12489] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:34.123 PrivacyBrowser[2568:12489] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:34.123 PrivacyBrowser[2568:12489] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:34.135 PrivacyBrowser[2568:12489] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:34.135 PrivacyBrowser[2568:12489] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:19:34.135 PrivacyBrowser[2568:12489] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:19:34.219 PrivacyBrowser[2568:12489] SafariWindow[69087470]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:19:34.219 PrivacyBrowser[2568:12489] SafariWindow[69087470]: document controller: BrowserDocumentController
2026-10-29 08:19:34.219 PrivacyBrowser[2568:12489] SafariWindow[69087470]: popup path, popup
2026-10-29 08:19:34.219 PrivacyBrowser[2568:12489] SafariWindow[69087470]: NSApplicationCrashOnExceptions: reads false; arguments NO, app unset, registered unset
2026-10-29 08:19:34.219 PrivacyBrowser[2568:12489] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:19:34.219 PrivacyBrowser[2568:12489] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:19:34.220 PrivacyBrowser[2568:12489] SafariWindow[69087470]: [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
2026-10-29 08:19:34.220 PrivacyBrowser[2568:12489] SafariWindow[69087470]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:19:34.220 PrivacyBrowser[2568:12489] SafariWindow[69087470]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   1   PrivacyBrowser                      0x000000010265d498 PBPreprocessException + 52
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   22  PrivacyBrowser                      0x0000000102776064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   23  PrivacyBrowser                      0x000000010276a2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   24  PrivacyBrowser                      0x000000010276df08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:19:34.359 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   25  PrivacyBrowser                      0x00000001027726c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:19:34.360 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   26  PrivacyBrowser                      0x000000010260e754 $sIeg_IeyB_TR + 28
2026-10-29 08:19:34.360 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   27  PrivacyBrowser                      0x000000010265d2f4 PBCatchException + 32
2026-10-29 08:19:34.360 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   28  PrivacyBrowser                      0x000000010276a068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:19:34.360 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   29  PrivacyBrowser                      0x000000010276c5b4 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3860
2026-10-29 08:19:34.360 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   30  PrivacyBrowser                      0x0000000102768c90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
2026-10-29 08:19:34.360 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   31  PrivacyBrowser                      0x0000000102780180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
2026-10-29 08:19:34.360 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   32  PrivacyBrowser                      0x000000010277e344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
2026-10-29 08:19:34.360 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   33  PrivacyBrowser                      0x000000010277ac99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:19:34.360 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   34  PrivacyBrowser                      0x0000000102780d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:19:34.360 PrivacyBrowser[2568:12489] SafariWindow[69087470]:   35  PrivacyBrowser                      0x000000010282a7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:19:34.360 PrivacyBrowser[2568:12489] SafariWindow[69087470]
```

## window:chrome — exited 0

```
PROBE step window
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: false
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments NO, app 1, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments NO, app 1, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments NO, app 1, registered unset
PROBE profile store: persistent 86627172-2176-4158-9011-75DFA80BD5B3
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup
PROBE   NSApplicationCrashOnExceptions: reads false; arguments NO, app 1, registered unset
PROBE   [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000100a1d498 PBPreprocessException + 52
PROBE     2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
PROBE     3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
PROBE     4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
PROBE     5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
PROBE     6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
PROBE     7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
PROBE     8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
PROBE     10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
PROBE     11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
PROBE     13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
PROBE     14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
PROBE     16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
PROBE     18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
PROBE     19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
PROBE     20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
PROBE     21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
PROBE     22  PrivacyBrowser                      0x0000000100b36064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
PROBE     23  PrivacyBrowser                      0x0000000100b2a2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     24  PrivacyBrowser                      0x0000000100b2df08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     25  PrivacyBrowser                      0x0000000100b326c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     26  PrivacyBrowser                      0x00000001009ce754 $sIeg_IeyB_TR + 28
PROBE     27  PrivacyBrowser                      0x0000000100a1d2f4 PBCatchException + 32
PROBE     28  PrivacyBrowser                      0x0000000100b2a068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     29  PrivacyBrowser                      0x0000000100b2c5b4 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3860
PROBE     30  PrivacyBrowser                      0x0000000100b28c90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
PROBE     31  PrivacyBrowser                      0x0000000100b270f8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 428
PROBE     32  PrivacyBrowser                      0x0000000100b3c014 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZ04$s14a9Browser20cde17O10windowStep33_9ijklmno11LLyyYaFZSo8p10CSgAA0cB16qr6C_So18stU24C10Foundation3URLVtXEfU_Tf1cn_nTY0_ + 1104
PROBE     33  PrivacyBrowser                      0x0000000100b3ae2d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ5_ + 1
PROBE     34  PrivacyBrowser                      0x0000000100b40d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     35  PrivacyBrowser                      0x0000000100bea7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     36  PrivacyBrowser                      0x0000000100bea815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     37  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
PROBE   -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
PROBE   popup path, popup: giving up — raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE   view tree: NSThemeFrame[NSVisualEffectView NSView[NSView[NSView[NSView[NSSplitView[… … … … …]]]]] NSTitlebarContainerView[_NSTitlebarDecorationView NSTitlebarView[NSVisualEffectView NSView _NSThemeCloseWidget _NSThemeZoomWidget _NSThemeWidget NSTextField NSToolbarView]]]
PROBE   UnifiedField views in the window: 0
PROBE   toolbar: BrowserToolbar, visible true; title bar accessories: none
PROBE   -unifiedField -> UnifiedField, superview UnifiedFieldContainerView, in a window false, hidden false, frame {{0, 0}, {343, 28}}
PROBE   _popupWindowUnifiedField -> nil
PROBE   the profile's store was handed out 0 times during the attempt
PROBE   no popup variant gave a usable window; going on with the ordinary window
PROBE   BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
PROBE   [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
PROBE   window controller: BrowserWindowController
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000100a1d498 PBPreprocessException + 52
PROBE     2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
PROBE     3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
PROBE     4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
PROBE     5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
PROBE     6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
PROBE     7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
PROBE     8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
PROBE     10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
PROBE     11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
PROBE     13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
PROBE     14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
PROBE     16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
PROBE     17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
PROBE     18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
PROBE     19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
PROBE     20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
PROBE     21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
PROBE     22  PrivacyBrowser                      0x0000000100b36064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
PROBE     23  PrivacyBrowser                      0x0000000100b2a2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     24  PrivacyBrowser                      0x0000000100b2df08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     25  PrivacyBrowser                      0x0000000100b326c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     26  PrivacyBrowser                      0x00000001009ce754 $sIeg_IeyB_TR + 28
PROBE     27  PrivacyBrowser                      0x0000000100a1d2f4 PBCatchException + 32
PROBE     28  PrivacyBrowser                      0x0000000100b2a068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     29  PrivacyBrowser                      0x0000000100b274b4 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1384
PROBE     30  PrivacyBrowser                      0x0000000100b3c014 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZ04$s14a9Browser20cde17O10windowStep33_9ijklmno11LLyyYaFZSo8p10CSgAA0cB16qr6C_So18stU24C10Foundation3URLVtXEfU_Tf1cn_nTY0_ + 1104
PROBE     31  PrivacyBrowser                      0x0000000100b3ae2d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ5_ + 1
PROBE     32  PrivacyBrowser                      0x0000000100b40d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     33  PrivacyBrowser                      0x0000000100bea7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     34  PrivacyBrowser                      0x0000000100bea815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     35  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
PROBE   -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
PROBE   giving up; the in-process web view path remains
PROBE RESULT no window
PROBE activation policy afterwards: 0 (0 = regular, 1 = accessory)
PROBE FALLBACK in-process window: visible=true url=https://example.com/ title=Example Domain
PROBE wrote fallback-window.png (15340 bytes)
PROBE wrote fallback-page.png (76051 bytes)
PROBE step window finished
2026-10-29 08:19:35.994 PrivacyBrowser[2621:12698] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:35.995 PrivacyBrowser[2621:12698] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:35.995 PrivacyBrowser[2621:12698] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:35.995 PrivacyBrowser[2621:12698] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:36.015 PrivacyBrowser[2621:12698] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:36.016 PrivacyBrowser[2621:12698] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:19:36.016 PrivacyBrowser[2621:12698] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:19:36.173 PrivacyBrowser[2621:12698] SafariWindow[86627172]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:19:36.173 PrivacyBrowser[2621:12698] SafariWindow[86627172]: document controller: BrowserDocumentController
2026-10-29 08:19:36.173 PrivacyBrowser[2621:12698] SafariWindow[86627172]: popup path, popup
2026-10-29 08:19:36.173 PrivacyBrowser[2621:12698] SafariWindow[86627172]: NSApplicationCrashOnExceptions: reads false; arguments NO, app 1, registered unset
2026-10-29 08:19:36.173 PrivacyBrowser[2621:12698] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:19:36.173 PrivacyBrowser[2621:12698] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:19:36.183 PrivacyBrowser[2621:12698] SafariWindow[86627172]: [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
2026-10-29 08:19:36.183 PrivacyBrowser[2621:12698] SafariWindow[86627172]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:19:36.183 PrivacyBrowser[2621:12698] SafariWindow[86627172]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:19:36.415 PrivacyBrowser[2621:12698] SafariWindow[86627172]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:19:36.415 PrivacyBrowser[2621:12698] SafariWindow[86627172]:   0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
2026-10-29 08:19:36.415 PrivacyBrowser[2621:12698] SafariWindow[86627172]:   1   PrivacyBrowser                      0x0000000100a1d498 PBPreprocessException + 52
2026-10-29 08:19:36.415 PrivacyBrowser[2621:12698] SafariWindow[86627172]:   2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
2026-10-29 08:19:36.415 PrivacyBrowser[2621:12698] SafariWindow[86627172]:   3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:19:36.415 PrivacyBrowser[2621:12698] SafariWindow[86627172]:   4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:19:36.415 PrivacyBrowser[2621:12698] SafariWindow[86627172]:   5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
2026-10-29 08:19:36.415 PrivacyBrowser[2621:12698] SafariWindow[86627172]:   6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
2026-10-29 08:19:36.415 PrivacyBrowser[2621:12698] SafariWindow[86627172]:   7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
2026-10-29 08:19:36.415 PrivacyBrowser[2621:12698] SafariWindow[86627172]:   8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:19:36.415 PrivacyBrowser[2621:12698] SafariWindow[86627172]:   9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
2026-10-29 08:19:36.415 PrivacyBrowser[2621:12698] SafariWindow[86627172]:   10  AppKit         
```
