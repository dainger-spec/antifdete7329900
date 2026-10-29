# Framework window probe

macOS 15.7.9 (24G830), arm64, SIP: System Integrity Protection status: disabled.
built with SDK 15.5, Xcode 16.4 Build version 16F6
app: build/sandboxed/PrivacyBrowser.app

| step | outcome | seconds | why |
|---|---|---|---|
| image | exited 0 | 0.4 |  |
| classes | exited 0 | 0.1 |  |
| selectors | exited 0 | 1.0 |  |
| appcontroller | exited 0 | 0.1 |  |
| windowcontroller | exited 0 | 0.1 |  |
| documentcontroller | exited 0 | 0.1 |  |
| documentcontroller-create | exited 0 | 0.2 |  |
| webconfig | exited 0 | 0.1 |  |
| shared | exited 0 | 0.1 |  |
| create-direct | killed by SIGSEGV | 0.2 | SIGNAL 11 / Segmentation fault: 11 / EXC_BAD_ACCESS SIGSEGV |
| create | exited 0 | 0.3 | raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value |
| create-bootstrap | exited 0 | 0.2 | raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value |
| window | exited 0 | 2.4 | raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; no window |
| popupfield | exited 0 | 0.2 |  |
| popup | exited 0 | 2.0 | raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; no window |
| popup-nofield | killed by SIGSEGV | 0.2 | SIGNAL 11 / Segmentation fault: 11 / EXC_BAD_ACCESS SIGSEGV |
| popup-mode | exited 0 | 2.5 | raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; no window |
| popup-hidden | exited 0 | 0.8 | raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x123f06820; no window |
| popup:crash-off | exited 0 | 0.9 | raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; no window |
| window:chrome | exited 0 | 1.1 | raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; no window |

## image — exited 0

```
PROBE step image
PROBE macOS Version 15.7.9 (Build 24G830)
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
2026-10-29 08:19:49.789 PrivacyBrowser[2883:13596] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:49.790 PrivacyBrowser[2883:13596] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:49.790 PrivacyBrowser[2883:13596] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:49.791 PrivacyBrowser[2883:13596] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:49.825 PrivacyBrowser[2883:13596] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## classes — exited 0

```
PROBE step classes
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: true
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
2026-10-29 08:19:49.874 PrivacyBrowser[2887:13635] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:49.874 PrivacyBrowser[2887:13635] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:49.874 PrivacyBrowser[2887:13635] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:49.874 PrivacyBrowser[2887:13635] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:49.882 PrivacyBrowser[2887:13635] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## selectors — exited 0

```
PROBE step selectors
PROBE macOS Version 15.7.9 (Build 24G830)
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
2026-10-29 08:19:49.948 PrivacyBrowser[2888:13639] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:49.948 PrivacyBrowser[2888:13639] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:49.948 PrivacyBrowser[2888:13639] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:49.949 PrivacyBrowser[2888:13639] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:49.960 PrivacyBrowser[2888:13639] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## appcontroller — exited 0

```
PROBE step appcontroller
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: true
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
2026-10-29 08:19:50.958 PrivacyBrowser[2890:13660] SafariLoader: classNames -> nil (framework image not in the loaded image list)
2026-10-29 08:19:50.959 PrivacyBrowser[2890:13660] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:50.959 PrivacyBrowser[2890:13660] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:50.959 PrivacyBrowser[2890:13660] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:50.959 PrivacyBrowser[2890:13660] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:50.967 PrivacyBrowser[2890:13660] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## windowcontroller — exited 0

```
PROBE step windowcontroller
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: true
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
2026-10-29 08:19:51.040 PrivacyBrowser[2891:13664] SafariLoader: classNames -> nil (framework image not in the loaded image list)
2026-10-29 08:19:51.040 PrivacyBrowser[2891:13664] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:51.040 PrivacyBrowser[2891:13664] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:51.040 PrivacyBrowser[2891:13664] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:51.041 PrivacyBrowser[2891:13664] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:51.049 PrivacyBrowser[2891:13664] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## documentcontroller — exited 0

```
PROBE step documentcontroller
PROBE macOS Version 15.7.9 (Build 24G830)
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
2026-10-29 08:19:51.161 PrivacyBrowser[2892:13672] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:51.162 PrivacyBrowser[2892:13672] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:51.162 PrivacyBrowser[2892:13672] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:51.162 PrivacyBrowser[2892:13672] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:51.170 PrivacyBrowser[2892:13672] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## documentcontroller-create — exited 0

```
PROBE step documentcontroller-create
PROBE macOS Version 15.7.9 (Build 24G830)
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
2026-10-29 08:19:51.396 PrivacyBrowser[2893:13678] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:51.398 PrivacyBrowser[2893:13678] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:51.398 PrivacyBrowser[2893:13678] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:51.398 PrivacyBrowser[2893:13678] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:51.405 PrivacyBrowser[2893:13678] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## webconfig — exited 0

```
PROBE step webconfig
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: true
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE configuration factories: _webViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:relatedWebView:groupIdentifier:preferences:userContentController:jitEnabled:preferencesManager:, _webViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:relatedWebView:groupIdentifier:preferences:userContentController:webExtensionsController:jitEnabled:preferencesManager:, automationPreferencesWithConfiguration:, contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:, contentWebViewConfigurationForBrowsingMode:profileIdentifier:jitEnabled:, readerWebViewConfigurationForBrowsingMode:profileIdentifier:relatedWebView:, webExtensionWebViewConfigurationForExtension:relatedWebView:, webExtensionWebViewConfigurationForExtensionsController:relatedWebView:
PROBE calling +[WebKitPreferencesManager contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:] for profile 0FBC3D44-8618-4164-8A11-588C7D7C4485 …
PROBE   contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier: -> WKWebViewConfiguration
PROBE   websiteDataStore: persistent 0FBC3D44-8618-4164-8A11-588C7D7C4485
PROBE with the profile's store bound: contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier: -> WKWebViewConfiguration
PROBE   per-profile store factory asked for 1F9B585E-FBAA-4D91-8520-6562110BE3EA -> handed it non-persistent
PROBE   websiteDataStore is the bound one: true
PROBE step webconfig finished
2026-10-29 08:19:51.432 PrivacyBrowser[2895:13741] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:51.432 PrivacyBrowser[2895:13741] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:51.432 PrivacyBrowser[2895:13741] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:51.432 PrivacyBrowser[2895:13741] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:51.441 PrivacyBrowser[2895:13741] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:51.489 PrivacyBrowser[2895:13741] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:19:51.489 PrivacyBrowser[2895:13741] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
```

## shared — exited 0

```
PROBE step shared
PROBE macOS Version 15.7.9 (Build 24G830)
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
2026-10-29 08:19:51.515 PrivacyBrowser[2896:13761] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:51.515 PrivacyBrowser[2896:13761] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:51.515 PrivacyBrowser[2896:13761] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:51.515 PrivacyBrowser[2896:13761] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:51.527 PrivacyBrowser[2896:13761] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:51.528 PrivacyBrowser[2896:13761] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:19:51.528 PrivacyBrowser[2896:13761] SafariWindow: +sharedDocumentController is now BrowserDocumentController
```

## create-direct — killed by SIGSEGV

```
PROBE step create-direct
PROBE macOS Version 15.7.9 (Build 24G830)
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
2026-10-29 08:19:51.647 PrivacyBrowser[2897:13770] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:51.648 PrivacyBrowser[2897:13770] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:19:51.648 PrivacyBrowser[2897:13770] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:51.648 PrivacyBrowser[2897:13770] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:19:51.660 PrivacyBrowser[2897:13770] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:19:51.661 PrivacyBrowser[2897:13770] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:19:51.661 PrivacyBrowser[2897:13770] SafariWindow: +sharedDocumentController is now BrowserDocumentController
```

Crash report `PrivacyBrowser-2026-10-29-081952.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:19:52.00 +0000",
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
    "incident_id": "DBDA47A4-2399-4F00-9D9B-E0DF98FD76CC"
  },
  "exception": {
    "codes": "0x0000000000000001, 0x0000623ef793a7e0",
    "rawCodes": [
      1,
      108022581143520
    ],
    "type": "EXC_BAD_ACCESS",
    "signal": "SIGSEGV",
    "subtype": "KERN_INVALID_ADDRESS at 0x0000623ef793a7e0"
  },
  "termination": {
    "flags": 0,
    "code": 11,
    "namespace": "SIGNAL",
    "indicator": "Segmentation fault: 11",
    "byProc": "exc handler",
    "byPid": 2897
  },
  "vmRegionInfo": "0x623ef793a7e0 is not in any region.  \n      REGION TYPE                    START - END         [ VSIZE] PRT/MAX SHRMOD  REGION DETAIL\n      UNUSED SPACE AT START\n--->  \n      UNUSED SPACE AT END",
  "faultingThread": 3,
  "triggered_frames": [
    "libobjc.A.dylib + 31024",
    "Foundation + 109156",
    "Foundation + 136776",
    "WebBookmarks + 69364",
    "libdispatch.dylib + 6956",
    "libdispatch.dylib + 112732",
    "libdispatch.dylib + 41808",
    "libdispatch.dylib + 44640",
    "libdispatch.dylib + 86628",
    "libdispatch.dylib + 84712",
    "libsystem_pthread.dylib + 11808",
    "libsystem_pthread.dylib + 7028"
  ]
}
```

## create — exited 0

```
PROBE step create
PROBE macOS Version 15.7.9 (Build 24G830)
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
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000102dc1498 PBPreprocessException + 52
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
PROBE     22  PrivacyBrowser                      0x0000000102eda064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
PROBE     23  PrivacyBrowser                      0x0000000102ece2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     24  PrivacyBrowser                      0x0000000102ed1f08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     25  PrivacyBrowser                      0x0000000102ed66c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     26  PrivacyBrowser                      0x0000000102d72754 $sIeg_IeyB_TR + 28
PROBE     27  PrivacyBrowser                      0x0000000102dc12f4 PBCatchException + 32
PROBE     28  PrivacyBrowser                      0x0000000102ece068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     29  PrivacyBrowser                      0x0000000102ecb4b4 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1384
PROBE     30  PrivacyBrowser                      0x0000000102edf694 $s14PrivacyBrowser20SafariFrameworkProbeO10createStep33_9F0153DCAF2CE7EC9F01CEB735D44942LL9bootstrapySb_tFZ + 496
PROBE     31  PrivacyBrowser                      0x0000000102edeb50 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TY0_ + 496
PROBE     32  PrivacyBrowser                      0x0000000102ee4d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     33  PrivacyBrowser                      0x0000000102f8e7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     34  PrivacyBrowser                      0x0000000102f8e815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     35  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
PROBE   -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
PROBE   giving up; the in-process web view path remains
PROBE window: nil
PROBE activation policy afterwards: 0 (0 = regular, 1 = accessory)
PROBE step create finished
2026-10-29 08:20:00.714 PrivacyBrowser[3009:14095] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:00.715 PrivacyBrowser[3009:14095] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:00.715 PrivacyBrowser[3009:14095] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:00.715 PrivacyBrowser[3009:14095] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:00.729 PrivacyBrowser[3009:14095] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:20:00.730 PrivacyBrowser[3009:14095] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:20:00.730 PrivacyBrowser[3009:14095] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:20:00.838 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:20:00.838 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]: document controller: BrowserDocumentController
2026-10-29 08:20:00.839 PrivacyBrowser[3009:14095] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:20:00.839 PrivacyBrowser[3009:14095] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:20:00.841 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]: BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
2026-10-29 08:20:00.842 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]: [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
2026-10-29 08:20:00.842 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]: window controller: BrowserWindowController
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   1   PrivacyBrowser                      0x0000000102dc1498 PBPreprocessException + 52
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   22  PrivacyBrowser                      0x0000000102eda064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   23  PrivacyBrowser                      0x0000000102ece2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   24  PrivacyBrowser                      0x0000000102ed1f08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   25  PrivacyBrowser                      0x0000000102ed66c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   26  PrivacyBrowser                      0x0000000102d72754 $sIeg_IeyB_TR + 28
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   27  PrivacyBrowser                      0x0000000102dc12f4 PBCatchException + 32
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   28  PrivacyBrowser                      0x0000000102ece068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   29  PrivacyBrowser                      0x0000000102ecb4b4 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1384
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   30  PrivacyBrowser                      0x0000000102edf694 $s14PrivacyBrowser20SafariFrameworkProbeO10createStep33_9F0153DCAF2CE7EC9F01CEB735D44942LL9bootstrapySb_tFZ + 496
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   31  PrivacyBrowser                      0x0000000102edeb50 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TY0_ + 496
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   32  PrivacyBrowser                      0x0000000102ee4d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   33  PrivacyBrowser                      0x0000000102f8e7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   34  PrivacyBrowser                      0x0000000102f8e815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
2026-10-29 08:20:00.966 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]:   35  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:20:00.968 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]: -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
2026-10-29 08:20:00.970 PrivacyBrowser[3009:14095] SafariWindow[2C06E8A9]: giving up; the in-process web view path remains
```

## create-bootstrap — exited 0

```
PROBE step create-bootstrap
PROBE macOS Version 15.7.9 (Build 24G830)
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
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x00000001008a5498 PBPreprocessException + 52
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
PROBE     22  PrivacyBrowser                      0x00000001009be064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
PROBE     23  PrivacyBrowser                      0x00000001009b22c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     24  PrivacyBrowser                      0x00000001009b5f08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     25  PrivacyBrowser                      0x00000001009ba6c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     26  PrivacyBrowser                      0x0000000100856754 $sIeg_IeyB_TR + 28
PROBE     27  PrivacyBrowser                      0x00000001008a52f4 PBCatchException + 32
PROBE     28  PrivacyBrowser                      0x00000001009b2068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     29  PrivacyBrowser                      0x00000001009af4b4 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1384
PROBE     30  PrivacyBrowser                      0x00000001009c3694 $s14PrivacyBrowser20SafariFrameworkProbeO10createStep33_9F0153DCAF2CE7EC9F01CEB735D44942LL9bootstrapySb_tFZ + 496
PROBE     31  PrivacyBrowser                      0x00000001009c2b50 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TY0_ + 496
PROBE     32  PrivacyBrowser                      0x00000001009c8d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     33  PrivacyBrowser                      0x0000000100a727c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     34  PrivacyBrowser                      0x0000000100a72815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     35  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
PROBE   -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
PROBE   giving up; the in-process web view path remains
PROBE window: nil
PROBE activation policy afterwards: 0 (0 = regular, 1 = accessory)
PROBE step create-bootstrap finished
2026-10-29 08:20:01.019 PrivacyBrowser[3010:14128] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:01.020 PrivacyBrowser[3010:14128] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:01.020 PrivacyBrowser[3010:14128] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:01.020 PrivacyBrowser[3010:14128] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:01.030 PrivacyBrowser[3010:14128] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:20:01.031 PrivacyBrowser[3010:14128] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:20:01.031 PrivacyBrowser[3010:14128] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:20:01.123 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:20:01.123 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]: document controller: BrowserDocumentController
2026-10-29 08:20:01.123 PrivacyBrowser[3010:14128] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:20:01.123 PrivacyBrowser[3010:14128] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:20:01.124 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]: BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
2026-10-29 08:20:01.125 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]: [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
2026-10-29 08:20:01.125 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]: window controller: BrowserWindowController
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   1   PrivacyBrowser                      0x00000001008a5498 PBPreprocessException + 52
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   22  PrivacyBrowser                      0x00000001009be064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   23  PrivacyBrowser                      0x00000001009b22c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   24  PrivacyBrowser                      0x00000001009b5f08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   25  PrivacyBrowser                      0x00000001009ba6c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   26  PrivacyBrowser                      0x0000000100856754 $sIeg_IeyB_TR + 28
2026-10-29 08:20:01.239 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   27  PrivacyBrowser                      0x00000001008a52f4 PBCatchException + 32
2026-10-29 08:20:01.240 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   28  PrivacyBrowser                      0x00000001009b2068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:20:01.240 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   29  PrivacyBrowser                      0x00000001009af4b4 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1384
2026-10-29 08:20:01.240 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   30  PrivacyBrowser                      0x00000001009c3694 $s14PrivacyBrowser20SafariFrameworkProbeO10createStep33_9F0153DCAF2CE7EC9F01CEB735D44942LL9bootstrapySb_tFZ + 496
2026-10-29 08:20:01.240 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   31  PrivacyBrowser                      0x00000001009c2b50 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TY0_ + 496
2026-10-29 08:20:01.240 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   32  PrivacyBrowser                      0x00000001009c8d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:20:01.240 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   33  PrivacyBrowser                      0x0000000100a727c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:20:01.240 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   34  PrivacyBrowser                      0x0000000100a72815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
2026-10-29 08:20:01.240 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]:   35  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:20:01.241 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]: -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
2026-10-29 08:20:01.242 PrivacyBrowser[3010:14128] SafariWindow[BD7BFC71]: giving up; the in-process web view path remains
```

## window — exited 0

```
PROBE step window
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: true
PROBE NSApplicationCrashOnExceptions at start: reads true; arguments YES, app 1, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads true; arguments YES, app 1, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads true; arguments YES, app 1, registered unset
PROBE profile store: persistent 958B7427-F0CC-476C-8E84-4888155BCD9D
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
PROBE   [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
PROBE   window controller: BrowserWindowController
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x000000010482d498 PBPreprocessException + 52
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
PROBE     22  PrivacyBrowser                      0x0000000104946064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
PROBE     23  PrivacyBrowser                      0x000000010493a2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     24  PrivacyBrowser                      0x000000010493df08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     25  PrivacyBrowser                      0x00000001049426c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     26  PrivacyBrowser                      0x00000001047de754 $sIeg_IeyB_TR + 28
PROBE     27  PrivacyBrowser                      0x000000010482d2f4 PBCatchException + 32
PROBE     28  PrivacyBrowser                      0x000000010493a068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     29  PrivacyBrowser                      0x00000001049374b4 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1384
PROBE     30  PrivacyBrowser                      0x000000010494c014 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZ04$s14a9Browser20cde17O10windowStep33_9ijklmno11LLyyYaFZSo8p10CSgAA0cB16qr6C_So18stU24C10Foundation3URLVtXEfU_Tf1cn_nTY0_ + 1104
PROBE     31  PrivacyBrowser                      0x000000010494ae2d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ5_ + 1
PROBE     32  PrivacyBrowser                      0x0000000104950d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     33  PrivacyBrowser                      0x00000001049fa7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     34  PrivacyBrowser                      0x00000001049fa815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     35  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
PROBE   -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
PROBE   giving up; the in-process web view path remains
PROBE RESULT no window
PROBE activation policy afterwards: 0 (0 = regular, 1 = accessory)
PROBE FALLBACK in-process window: visible=true url=https://example.com/ title=Example Domain
PROBE wrote fallback-window.png (15340 bytes)
PROBE wrote fallback-page.png (76051 bytes)
PROBE step window finished
2026-10-29 08:20:01.268 PrivacyBrowser[3011:14142] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:01.268 PrivacyBrowser[3011:14142] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:01.268 PrivacyBrowser[3011:14142] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:01.268 PrivacyBrowser[3011:14142] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:01.277 PrivacyBrowser[3011:14142] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:20:01.278 PrivacyBrowser[3011:14142] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:20:01.278 PrivacyBrowser[3011:14142] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:20:01.392 PrivacyBrowser[3011:14142] SafariWindow[958B7427]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:20:01.392 PrivacyBrowser[3011:14142] SafariWindow[958B7427]: document controller: BrowserDocumentController
2026-10-29 08:20:01.392 PrivacyBrowser[3011:14142] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:20:01.392 PrivacyBrowser[3011:14142] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:20:01.394 PrivacyBrowser[3011:14142] SafariWindow[958B7427]: BrowserWindowController declares these initialisers: init, initAsPopupWindow:, initWithBrowsingMode:isPopupWindow:
2026-10-29 08:20:01.395 PrivacyBrowser[3011:14142] SafariWindow[958B7427]: [[BrowserWindowController alloc] initWithBrowsingMode:isPopupWindow:]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
2026-10-29 08:20:01.395 PrivacyBrowser[3011:14142] SafariWindow[958B7427]: window controller: BrowserWindowController
2026-10-29 08:20:01.505 PrivacyBrowser[3011:14142] SafariWindow[958B7427]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:20:01.505 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   1   PrivacyBrowser                      0x000000010482d498 PBPreprocessException + 52
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   22  PrivacyBrowser                      0x0000000104946064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   23  PrivacyBrowser                      0x000000010493a2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   24  PrivacyBrowser                      0x000000010493df08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   25  PrivacyBrowser                      0x00000001049426c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   26  PrivacyBrowser                      0x00000001047de754 $sIeg_IeyB_TR + 28
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   27  PrivacyBrowser                      0x000000010482d2f4 PBCatchException + 32
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   28  PrivacyBrowser                      0x000000010493a068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   29  PrivacyBrowser                      0x00000001049374b4 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1384
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   30  PrivacyBrowser                      0x000000010494c014 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZ04$s14a9Browser20cde17O10windowStep33_9ijklmno11LLyyYaFZSo8p10CSgAA0cB16qr6C_So18stU24C10Foundation3URLVtXEfU_Tf1cn_nTY0_ + 1104
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   31  PrivacyBrowser                      0x000000010494ae2d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ5_ + 1
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   32  PrivacyBrowser                      0x0000000104950d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   33  PrivacyBrowser                      0x00000001049fa7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   34  PrivacyBrowser                      0x00000001049fa815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]:   35  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:20:01.506 PrivacyBrowser[3011:14142] SafariWindow[958B7427]: -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
2026-10-29 08:20:01.509 PrivacyBrowser[3011:14142] SafariWindow[958B7427]: giving up; the in-process web view path remains
```

## popupfield — exited 0

```
PROBE step popupfield
PROBE macOS Version 15.7.9 (Build 24G830)
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
2026-10-29 08:20:03.695 PrivacyBrowser[3018:14259] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:03.696 PrivacyBrowser[3018:14259] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:03.696 PrivacyBrowser[3018:14259] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:03.696 PrivacyBrowser[3018:14259] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:03.704 PrivacyBrowser[3018:14259] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
```

## popup — exited 0

```
PROBE step popup
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: true
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments unset, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments unset, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments unset, app unset, registered unset
PROBE profile store: persistent 42CFAAC0-4623-4386-9A60-4094C465CDA4
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup
PROBE   NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
PROBE   [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000102e49498 PBPreprocessException + 52
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
PROBE     22  PrivacyBrowser                      0x0000000102f62064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
PROBE     23  PrivacyBrowser                      0x0000000102f562c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     24  PrivacyBrowser                      0x0000000102f59f08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     25  PrivacyBrowser                      0x0000000102f5e6c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     26  PrivacyBrowser                      0x0000000102dfa754 $sIeg_IeyB_TR + 28
PROBE     27  PrivacyBrowser                      0x0000000102e492f4 PBCatchException + 32
PROBE     28  PrivacyBrowser                      0x0000000102f56068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     29  PrivacyBrowser                      0x0000000102f585b4 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3860
PROBE     30  PrivacyBrowser                      0x0000000102f54c90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
PROBE     31  PrivacyBrowser                      0x0000000102f6c180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
PROBE     32  PrivacyBrowser                      0x0000000102f6a344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
PROBE     33  PrivacyBrowser                      0x0000000102f66c99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     34  PrivacyBrowser                      0x0000000102f6cd69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     35  PrivacyBrowser                      0x00000001030167c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     36  PrivacyBrowser                      0x0000000103016815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
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
2026-10-29 08:20:03.865 PrivacyBrowser[3020:14300] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:03.866 PrivacyBrowser[3020:14300] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:03.866 PrivacyBrowser[3020:14300] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:03.866 PrivacyBrowser[3020:14300] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:03.878 PrivacyBrowser[3020:14300] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:20:03.879 PrivacyBrowser[3020:14300] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:20:03.879 PrivacyBrowser[3020:14300] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:20:03.975 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:20:03.976 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]: document controller: BrowserDocumentController
2026-10-29 08:20:03.976 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]: popup path, popup
2026-10-29 08:20:03.976 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]: NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
2026-10-29 08:20:03.976 PrivacyBrowser[3020:14300] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:20:03.976 PrivacyBrowser[3020:14300] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:20:03.980 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]: [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
2026-10-29 08:20:03.980 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:20:03.980 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   1   PrivacyBrowser                      0x0000000102e49498 PBPreprocessException + 52
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   22  PrivacyBrowser                      0x0000000102f62064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   23  PrivacyBrowser                      0x0000000102f562c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   24  PrivacyBrowser                      0x0000000102f59f08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:20:04.134 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   25  PrivacyBrowser                      0x0000000102f5e6c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:20:04.135 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   26  PrivacyBrowser                      0x0000000102dfa754 $sIeg_IeyB_TR + 28
2026-10-29 08:20:04.135 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   27  PrivacyBrowser                      0x0000000102e492f4 PBCatchException + 32
2026-10-29 08:20:04.135 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   28  PrivacyBrowser                      0x0000000102f56068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:20:04.135 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   29  PrivacyBrowser                      0x0000000102f585b4 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3860
2026-10-29 08:20:04.135 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   30  PrivacyBrowser                      0x0000000102f54c90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
2026-10-29 08:20:04.135 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   31  PrivacyBrowser                      0x0000000102f6c180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
2026-10-29 08:20:04.135 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   32  PrivacyBrowser                      0x0000000102f6a344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
2026-10-29 08:20:04.135 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   33  PrivacyBrowser                      0x0000000102f66c99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:20:04.135 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   34  PrivacyBrowser                      0x0000000102f6cd69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:20:04.135 PrivacyBrowser[3020:14300] SafariWindow[42CFAAC0]:   35  PrivacyBrowser                      0x00000001030167c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:20:04.135 PrivacyBrowser[3020:14300] SafariWi
```

## popup-nofield — killed by SIGSEGV

```
PROBE step popup-nofield
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: true
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments unset, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments unset, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments unset, app unset, registered unset
PROBE profile store: persistent E3925FEC-D94E-45B2-A753-76859EDC9A58
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup-nofield
PROBE   NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
PROBE   [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   setPopupWindowUnifiedFieldVisible:NO -> sent; isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:20:06.645 PrivacyBrowser[3029:14418] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:06.645 PrivacyBrowser[3029:14418] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:06.646 PrivacyBrowser[3029:14418] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:06.646 PrivacyBrowser[3029:14418] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:06.654 PrivacyBrowser[3029:14418] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:20:06.654 PrivacyBrowser[3029:14418] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:20:06.654 PrivacyBrowser[3029:14418] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:20:06.740 PrivacyBrowser[3029:14418] SafariWindow[E3925FEC]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:20:06.740 PrivacyBrowser[3029:14418] SafariWindow[E3925FEC]: document controller: BrowserDocumentController
2026-10-29 08:20:06.740 PrivacyBrowser[3029:14418] SafariWindow[E3925FEC]: popup path, popup-nofield
2026-10-29 08:20:06.741 PrivacyBrowser[3029:14418] SafariWindow[E3925FEC]: NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
2026-10-29 08:20:06.741 PrivacyBrowser[3029:14418] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:20:06.741 PrivacyBrowser[3029:14418] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:20:06.743 PrivacyBrowser[3029:14418] SafariWindow[E3925FEC]: [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
2026-10-29 08:20:06.744 PrivacyBrowser[3029:14418] SafariWindow[E3925FEC]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:20:06.744 PrivacyBrowser[3029:14418] SafariWindow[E3925FEC]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:20:06.744 PrivacyBrowser[3029:14418] SafariWindow[E3925FEC]: setPopupWindowUnifiedFieldVisible:NO -> sent; isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
```

Crash report `PrivacyBrowser-2026-10-29-082007.ips`:

```
{
  "header": {
    "app_name": "PrivacyBrowser",
    "timestamp": "2026-10-29 08:20:07.00 +0000",
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
    "incident_id": "BCD559A2-CF96-4047-A265-FE52E9D830FA"
  },
  "exception": {
    "codes": "0x0000000000000001, 0x0000782df1450fc0",
    "rawCodes": [
      1,
      132138716696512
    ],
    "type": "EXC_BAD_ACCESS",
    "signal": "SIGSEGV",
    "subtype": "KERN_INVALID_ADDRESS at 0x0000782df1450fc0"
  },
  "termination": {
    "flags": 0,
    "code": 11,
    "namespace": "SIGNAL",
    "indicator": "Segmentation fault: 11",
    "byProc": "exc handler",
    "byPid": 3029
  },
  "vmRegionInfo": "0x782df1450fc0 is not in any region.  \n      REGION TYPE                    START - END         [ VSIZE] PRT/MAX SHRMOD  REGION DETAIL\n      UNUSED SPACE AT START\n--->  \n      UNUSED SPACE AT END",
  "faultingThread": 3,
  "triggered_frames": [
    "libobjc.A.dylib + 31024",
    "Foundation + 109140",
    "Foundation + 136776",
    "WebBookmarks + 69364",
    "libdispatch.dylib + 6956",
    "libdispatch.dylib + 112732",
    "libdispatch.dylib + 41808",
    "libdispatch.dylib + 44640",
    "libdispatch.dylib + 86628",
    "libdispatch.dylib + 84712",
    "libsystem_pthread.dylib + 11808",
    "libsystem_pthread.dylib + 7028"
  ]
}
```

## popup-mode — exited 0

```
PROBE step popup-mode
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: true
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments unset, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments unset, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments unset, app unset, registered unset
PROBE profile store: persistent D14FA85E-E1E2-487F-B39C-D34A7E55CC09
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup-mode
PROBE   NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
PROBE   [[BrowserWindowController alloc] initWithBrowsingMode:0 isPopupWindow:YES]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000100d2d498 PBPreprocessException + 52
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
PROBE     22  PrivacyBrowser                      0x0000000100e46064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
PROBE     23  PrivacyBrowser                      0x0000000100e3a2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     24  PrivacyBrowser                      0x0000000100e3df08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     25  PrivacyBrowser                      0x0000000100e426c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     26  PrivacyBrowser                      0x0000000100cde754 $sIeg_IeyB_TR + 28
PROBE     27  PrivacyBrowser                      0x0000000100d2d2f4 PBCatchException + 32
PROBE     28  PrivacyBrowser                      0x0000000100e3a068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     29  PrivacyBrowser                      0x0000000100e3c5b4 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3860
PROBE     30  PrivacyBrowser                      0x0000000100e38c90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
PROBE     31  PrivacyBrowser                      0x0000000100e50180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
PROBE     32  PrivacyBrowser                      0x0000000100e4e344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
PROBE     33  PrivacyBrowser                      0x0000000100e4ac99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     34  PrivacyBrowser                      0x0000000100e50d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     35  PrivacyBrowser                      0x0000000100efa7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     36  PrivacyBrowser                      0x0000000100efa815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
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
2026-10-29 08:20:15.901 PrivacyBrowser[3206:15045] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:15.901 PrivacyBrowser[3206:15045] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:15.902 PrivacyBrowser[3206:15045] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:15.902 PrivacyBrowser[3206:15045] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:15.922 PrivacyBrowser[3206:15045] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:20:15.923 PrivacyBrowser[3206:15045] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:20:15.923 PrivacyBrowser[3206:15045] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:20:16.068 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:20:16.068 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]: document controller: BrowserDocumentController
2026-10-29 08:20:16.068 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]: popup path, popup-mode
2026-10-29 08:20:16.068 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]: NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
2026-10-29 08:20:16.068 PrivacyBrowser[3206:15045] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:20:16.069 PrivacyBrowser[3206:15045] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:20:16.072 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]: [[BrowserWindowController alloc] initWithBrowsingMode:0 isPopupWindow:YES]: initWithBrowsingMode:isPopupWindow: -> BrowserWindowController
2026-10-29 08:20:16.072 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:20:16.072 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   1   PrivacyBrowser                      0x0000000100d2d498 PBPreprocessException + 52
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   22  PrivacyBrowser                      0x0000000100e46064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   23  PrivacyBrowser                      0x0000000100e3a2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   24  PrivacyBrowser                      0x0000000100e3df08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:20:16.211 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   25  PrivacyBrowser                      0x0000000100e426c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:20:16.212 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   26  PrivacyBrowser                      0x0000000100cde754 $sIeg_IeyB_TR + 28
2026-10-29 08:20:16.212 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   27  PrivacyBrowser                      0x0000000100d2d2f4 PBCatchException + 32
2026-10-29 08:20:16.212 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   28  PrivacyBrowser                      0x0000000100e3a068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:20:16.212 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   29  PrivacyBrowser                      0x0000000100e3c5b4 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3860
2026-10-29 08:20:16.212 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   30  PrivacyBrowser                      0x0000000100e38c90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
2026-10-29 08:20:16.212 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   31  PrivacyBrowser                      0x0000000100e50180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
2026-10-29 08:20:16.212 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   32  PrivacyBrowser                      0x0000000100e4e344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
2026-10-29 08:20:16.212 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   33  PrivacyBrowser                      0x0000000100e4ac99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:20:16.212 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   34  PrivacyBrowser                      0x0000000100e50d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:20:16.212 PrivacyBrowser[3206:15045] SafariWindow[D14FA85E]:   35  PrivacyBrowser                      0x0000000100efa7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8Send
```

## popup-hidden — exited 0

```
PROBE step popup-hidden
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: true
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments unset, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments unset, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments unset, app unset, registered unset
PROBE profile store: persistent 7F110223-68EB-4DF3-B5D7-BE3F36E62564
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup-hidden
PROBE   NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
PROBE   RAISED NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x123f06820
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000100f91498 PBPreprocessException + 52
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
PROBE     12  PrivacyBrowser                      0x00000001010ad214 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObject__7integer6object4flagSo8NSObjectCSg5value_SS6reasontyXl_SSSiyXlSgSbtFZTf4nnnnnd_n + 140
PROBE     13  PrivacyBrowser                      0x00000001010a1d9c $s14PrivacyBrowser06SafariB16WindowControllerC011createPopupE033_D5663EB8AEBCFB374BED3A50E441DB28LL_2ofSo8NSObjectCSgAC0G7VariantO_yXlXptF + 384
PROBE     14  PrivacyBrowser                      0x00000001010a1be8 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU_ + 36
PROBE     15  PrivacyBrowser                      0x0000000100f42754 $sIeg_IeyB_TR + 28
PROBE     16  PrivacyBrowser                      0x0000000100f912f4 PBCatchException + 32
PROBE     17  PrivacyBrowser                      0x000000010109e068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     18  PrivacyBrowser                      0x000000010109f7a0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 256
PROBE     19  PrivacyBrowser                      0x000000010109cc90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
PROBE     20  PrivacyBrowser                      0x00000001010b4180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
PROBE     21  PrivacyBrowser                      0x00000001010b2344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
PROBE     22  PrivacyBrowser                      0x00000001010aec99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     23  PrivacyBrowser                      0x00000001010b4d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     24  PrivacyBrowser                      0x000000010115e7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     25  PrivacyBrowser                      0x000000010115e815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     26  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
PROBE   creating the controller raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x123f06820; caught, so the attempt ends and the process does not
PROBE   popup path, popup-hidden: giving up — raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x123f06820
PROBE   the profile's store was handed out 3 times during the attempt
PROBE     per-profile store factory asked for 7F110223-68EB-4DF3-B5D7-BE3F36E62564 -> handed it persistent 7F110223-68EB-4DF3-B5D7-BE3F36E62564
PROBE     per-profile store factory asked for 7F110223-68EB-4DF3-B5D7-BE3F36E62564 -> handed it persistent 7F110223-68EB-4DF3-B5D7-BE3F36E62564
PROBE     websiteDataStore read on WKWebViewConfiguration -> persistent 7F110223-68EB-4DF3-B5D7-BE3F36E62564
PROBE RESULT no window
PROBE activation policy afterwards: 0 (0 = regular, 1 = accessory)
PROBE FALLBACK in-process window: visible=true url=https://example.com/ title=Example Domain
PROBE wrote fallback-window.png (15340 bytes)
PROBE wrote fallback-page.png (76051 bytes)
PROBE step popup-hidden finished
2026-10-29 08:20:19.305 PrivacyBrowser[3222:15275] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:19.305 PrivacyBrowser[3222:15275] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:19.305 PrivacyBrowser[3222:15275] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:19.305 PrivacyBrowser[3222:15275] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:19.316 PrivacyBrowser[3222:15275] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:20:19.316 PrivacyBrowser[3222:15275] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:20:19.316 PrivacyBrowser[3222:15275] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:20:19.411 PrivacyBrowser[3222:15275] SafariWindow[7F110223]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:20:19.411 PrivacyBrowser[3222:15275] SafariWindow[7F110223]: document controller: BrowserDocumentController
2026-10-29 08:20:19.411 PrivacyBrowser[3222:15275] SafariWindow[7F110223]: popup path, popup-hidden
2026-10-29 08:20:19.411 PrivacyBrowser[3222:15275] SafariWindow[7F110223]: NSApplicationCrashOnExceptions: reads false; arguments unset, app unset, registered unset
2026-10-29 08:20:19.411 PrivacyBrowser[3222:15275] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:20:19.411 PrivacyBrowser[3222:15275] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]: RAISED NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x123f06820
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   1   PrivacyBrowser                      0x0000000100f91498 PBPreprocessException + 52
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   3   CoreFoundation                      0x0000000184144800 -[NSObject(NSObject) __retain_OA] + 0
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   4   CoreFoundation                      0x0000000183ff59dc ___forwarding___ + 1500
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   5   CoreFoundation                      0x0000000183ff5340 _CF_forwarding_prep_0 + 96
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   6   Safari                              0x00000001b688f7b0 -[BrowserDocument makeWindowControllers] + 168
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   7   Safari                              0x00000001b689b58c -[BrowserDocumentController _createBrowserDocumentWithBrowsingMode:profileIdentifier:configuration:initialSize:options:] + 144
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   8   Safari                              0x00000001b689b47c -[BrowserDocumentController _createBrowserDocumentWithBrowsingMode:profileIdentifier:initialSize:options:] + 232
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   9   Safari                              0x00000001b6897350 -[BrowserDocumentController createHiddenEmptyBrowserDocumentWithBrowsingMode:profileIdentifier:jitEnabled:isPopupWindow:restoringFromLastSession:initialSize:] + 64
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   10  Safari                              0x00000001b6989a98 +[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:restoringFromLastSession:] + 108
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   11  Safari                              0x00000001b6989b3c +[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:] + 20
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   12  PrivacyBrowser                      0x00000001010ad214 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObject__7integer6object4flagSo8NSObjectCSg5value_SS6reasontyXl_SSSiyXlSgSbtFZTf4nnnnnd_n + 140
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   13  PrivacyBrowser                      0x00000001010a1d9c $s14PrivacyBrowser06SafariB16WindowControllerC011createPopupE033_D5663EB8AEBCFB374BED3A50E441DB28LL_2ofSo8NSObjectCSgAC0G7VariantO_yXlXptF + 384
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   14  PrivacyBrowser                      0x00000001010a1be8 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU_ + 36
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   15  PrivacyBrowser                      0x0000000100f42754 $sIeg_IeyB_TR + 28
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   16  PrivacyBrowser                      0x0000000100f912f4 PBCatchException + 32
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   17  PrivacyBrowser                      0x000000010109e068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   18  PrivacyBrowser                      0x000000010109f7a0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 256
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   19  PrivacyBrowser                      0x000000010109cc90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   20  PrivacyBrowser                      0x00000001010b4180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   21  PrivacyBrowser                      0x00000001010b2344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   22  PrivacyBrowser                      0x00000001010aec99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   23  PrivacyBrowser                      0x00000001010b4d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   24  PrivacyBrowser                      0x000000010115e7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   25  PrivacyBrowser                      0x000000010115e815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
2026-10-29 08:20:19.434 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   26  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
2026-10-29 08:20:19.436 PrivacyBrowser[3222:15275] SafariWindow[7F110223]: creating the controller raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x123f06820; caught, so the attempt ends and the process does not
2026-10-29 08:20:19.436 PrivacyBrowser[3222:15275] SafariWindow[7F110223]: popup path, popup-hidden: giving up — raised NSInvalidArgumentException: -[NSApplication isRestoringWindows]: unrecognized selector sent to instance 0x123f06820
2026-10-29 08:20:19.436 PrivacyBrowser[3222:15275] SafariWindow[7F110223]: the profile's store was handed out 3 times during the attempt
2026-10-29 08:20:19.436 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   per-profile store factory asked for 7F110223-68EB-4DF3-B5D7-BE3F36E62564 -> handed it persistent 7F110223-68EB-4DF3-B5D7-BE3F36E62564
2026-10-29 08:20:19.436 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   per-profile store factory asked for 7F110223-68EB-4DF3-B5D7-BE3F36E62564 -> handed it persistent 7F110223-68EB-4DF3-B5D7-BE3F36E62564
2026-10-29 08:20:19.436 PrivacyBrowser[3222:15275] SafariWindow[7F110223]:   websiteDataStore read on WKWebViewConfiguration -> persistent 7F110223-68EB-4DF3-B5D7-BE3F36E62564
```

## popup:crash-off — exited 0

```
PROBE step popup
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: true
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments NO, app unset, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments NO, app unset, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments NO, app unset, registered unset
PROBE profile store: persistent 72881E4D-EE05-4B28-B508-6E92C9A63A9F
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup
PROBE   NSApplicationCrashOnExceptions: reads false; arguments NO, app unset, registered unset
PROBE   [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x0000000104e9d498 PBPreprocessException + 52
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
PROBE     22  PrivacyBrowser                      0x0000000104fb6064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
PROBE     23  PrivacyBrowser                      0x0000000104faa2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     24  PrivacyBrowser                      0x0000000104fadf08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     25  PrivacyBrowser                      0x0000000104fb26c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     26  PrivacyBrowser                      0x0000000104e4e754 $sIeg_IeyB_TR + 28
PROBE     27  PrivacyBrowser                      0x0000000104e9d2f4 PBCatchException + 32
PROBE     28  PrivacyBrowser                      0x0000000104faa068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     29  PrivacyBrowser                      0x0000000104fac5b4 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3860
PROBE     30  PrivacyBrowser                      0x0000000104fa8c90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
PROBE     31  PrivacyBrowser                      0x0000000104fc0180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
PROBE     32  PrivacyBrowser                      0x0000000104fbe344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
PROBE     33  PrivacyBrowser                      0x0000000104fbac99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
PROBE     34  PrivacyBrowser                      0x0000000104fc0d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     35  PrivacyBrowser                      0x000000010506a7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     36  PrivacyBrowser                      0x000000010506a815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
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
2026-10-29 08:20:21.154 PrivacyBrowser[3305:15562] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:21.155 PrivacyBrowser[3305:15562] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:21.155 PrivacyBrowser[3305:15562] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:21.155 PrivacyBrowser[3305:15562] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:21.172 PrivacyBrowser[3305:15562] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:20:21.173 PrivacyBrowser[3305:15562] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:20:21.173 PrivacyBrowser[3305:15562] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:20:21.272 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:20:21.272 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]: document controller: BrowserDocumentController
2026-10-29 08:20:21.273 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]: popup path, popup
2026-10-29 08:20:21.273 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]: NSApplicationCrashOnExceptions: reads false; arguments NO, app unset, registered unset
2026-10-29 08:20:21.273 PrivacyBrowser[3305:15562] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:20:21.273 PrivacyBrowser[3305:15562] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:20:21.275 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]: [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
2026-10-29 08:20:21.275 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:20:21.275 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   1   PrivacyBrowser                      0x0000000104e9d498 PBPreprocessException + 52
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   10  AppKit                              0x0000000188a57e40 __36-[NSView _layoutSubtreeWithOldSize:]_block_invoke + 372
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   11  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   12  AppKit                              0x0000000187f7c86c -[NSView _layoutSubtreeWithOldSize:] + 100
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   13  AppKit                              0x0000000188a58a1c __56-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]_block_invoke + 908
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   14  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   15  AppKit                              0x0000000187f7c444 -[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:] + 100
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   16  AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   17  AppKit                              0x0000000187f7c3d4 -[NSView layoutSubtreeIfNeeded] + 96
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   18  Safari                              0x00000001b695a6b0 -[BrowserWindowController windowDidLoad] + 1068
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   19  AppKit                              0x000000018809c818 -[NSWindowController _windowDidLoad] + 620
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   20  Safari                              0x00000001b6e161a4 -[WindowController _windowDidLoad] + 52
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   21  AppKit                              0x0000000188098b2c -[NSWindowController window] + 100
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   22  PrivacyBrowser                      0x0000000104fb6064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   23  PrivacyBrowser                      0x0000000104faa2c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   24  PrivacyBrowser                      0x0000000104fadf08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
2026-10-29 08:20:21.404 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   25  PrivacyBrowser                      0x0000000104fb26c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
2026-10-29 08:20:21.405 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   26  PrivacyBrowser                      0x0000000104e4e754 $sIeg_IeyB_TR + 28
2026-10-29 08:20:21.405 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   27  PrivacyBrowser                      0x0000000104e9d2f4 PBCatchException + 32
2026-10-29 08:20:21.405 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   28  PrivacyBrowser                      0x0000000104faa068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
2026-10-29 08:20:21.405 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   29  PrivacyBrowser                      0x0000000104fac5b4 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3860
2026-10-29 08:20:21.405 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   30  PrivacyBrowser                      0x0000000104fa8c90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
2026-10-29 08:20:21.405 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   31  PrivacyBrowser                      0x0000000104fc0180 $s14PrivacyBrowser20SafariFrameworkProbeO9popupStep33_9F0153DCAF2CE7EC9F01CEB735D44942LLyyAA0cB16WindowControllerC12PopupVariantOYaFZSo8NSWindowCSgAG_So18WKWebsiteDataStoreC10Foundation3URLVtXEfU_ + 180
2026-10-29 08:20:21.405 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   32  PrivacyBrowser                      0x0000000104fbe344 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZTY0_ + 1064
2026-10-29 08:20:21.405 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   33  PrivacyBrowser                      0x0000000104fbac99 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ2_ + 1
2026-10-29 08:20:21.405 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   34  PrivacyBrowser                      0x0000000104fc0d69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
2026-10-29 08:20:21.405 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:   35  PrivacyBrowser                      0x000000010506a7c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
2026-10-29 08:20:21.405 PrivacyBrowser[3305:15562] SafariWindow[72881E4D]:
```

## window:chrome — exited 0

```
PROBE step window
PROBE macOS Version 15.7.9 (Build 24G830)
PROBE sandboxed: true
PROBE NSApplicationCrashOnExceptions at start: reads false; arguments NO, app 1, registered unset
PROBE prepareProcess: true
PROBE shared document controller is now BrowserDocumentController
PROBE NSApplicationCrashOnExceptions with the framework loaded: reads false; arguments NO, app 1, registered unset
PROBE NSApplicationCrashOnExceptions with the application running: reads false; arguments NO, app 1, registered unset
PROBE profile store: persistent 65500C99-05E9-41F4-99AE-C9D2B6285A02
PROBE   framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
PROBE   document controller: BrowserDocumentController
PROBE   popup path, popup
PROBE   NSApplicationCrashOnExceptions: reads false; arguments NO, app 1, registered unset
PROBE   [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
PROBE   popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
PROBE   isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
PROBE   RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
PROBE     0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
PROBE     1   PrivacyBrowser                      0x00000001040e9498 PBPreprocessException + 52
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
PROBE     22  PrivacyBrowser                      0x0000000104202064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
PROBE     23  PrivacyBrowser                      0x00000001041f62c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     24  PrivacyBrowser                      0x00000001041f9f08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     25  PrivacyBrowser                      0x00000001041fe6c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     26  PrivacyBrowser                      0x000000010409a754 $sIeg_IeyB_TR + 28
PROBE     27  PrivacyBrowser                      0x00000001040e92f4 PBCatchException + 32
PROBE     28  PrivacyBrowser                      0x00000001041f6068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     29  PrivacyBrowser                      0x00000001041f85b4 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOF + 3860
PROBE     30  PrivacyBrowser                      0x00000001041f4c90 $s14PrivacyBrowser06SafariB16WindowControllerC12attemptPopup33_D5663EB8AEBCFB374BED3A50E441DB28LL_9dataStore8startURLSo8NSWindowCSgAC0G7VariantO_So013WKWebsiteDataP0CSg10Foundation0R0VSgtF + 712
PROBE     31  PrivacyBrowser                      0x00000001041f30f8 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 428
PROBE     32  PrivacyBrowser                      0x0000000104208014 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZ04$s14a9Browser20cde17O10windowStep33_9ijklmno11LLyyYaFZSo8p10CSgAA0cB16qr6C_So18stU24C10Foundation3URLVtXEfU_Tf1cn_nTY0_ + 1104
PROBE     33  PrivacyBrowser                      0x0000000104206e2d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ5_ + 1
PROBE     34  PrivacyBrowser                      0x000000010420cd69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     35  PrivacyBrowser                      0x00000001042b67c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     36  PrivacyBrowser                      0x00000001042b6815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
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
PROBE     1   PrivacyBrowser                      0x00000001040e9498 PBPreprocessException + 52
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
PROBE     22  PrivacyBrowser                      0x0000000104202064 $s14PrivacyBrowser11ObjCRuntimeO19callReturningObjectySo8NSObjectCSg5value_SS6reasontyXl_SStFZTf4nnd_n + 960
PROBE     23  PrivacyBrowser                      0x00000001041f62c4 $s14PrivacyBrowser06SafariB16WindowControllerC04loadD033_D5663EB8AEBCFB374BED3A50E441DB28LL2ofSo8NSWindowCSgSo8NSObjectC_tF + 48
PROBE     24  PrivacyBrowser                      0x00000001041f9f08 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtFyycfU0_Tm + 32
PROBE     25  PrivacyBrowser                      0x00000001041fe6c0 $s14PrivacyBrowser06SafariB16WindowControllerC10buildPopup33_D5663EB8AEBCFB374BED3A50E441DB28LLySbAC0G7VariantOFyycfU1_TA + 20
PROBE     26  PrivacyBrowser                      0x000000010409a754 $sIeg_IeyB_TR + 28
PROBE     27  PrivacyBrowser                      0x00000001040e92f4 PBCatchException + 32
PROBE     28  PrivacyBrowser                      0x00000001041f6068 $s14PrivacyBrowser06SafariB16WindowControllerC7guarded33_D5663EB8AEBCFB374BED3A50E441DB28LLySbSS_yyctF + 136
PROBE     29  PrivacyBrowser                      0x00000001041f34b4 $s14PrivacyBrowser06SafariB16WindowControllerC4open9dataStore8startURLSo8NSWindowCSgSo013WKWebsiteDataH0CSg_10Foundation0J0VSgtF + 1384
PROBE     30  PrivacyBrowser                      0x0000000104208014 $s14PrivacyBrowser20SafariFrameworkProbeO12openAndCheck33_9F0153DCAF2CE7EC9F01CEB735D44942LLyySo8NSWindowCSgAA0cB16WindowControllerC_So18WKWebsiteDataStoreC10Foundation3URLVtXEYaFZ04$s14a9Browser20cde17O10windowStep33_9ijklmno11LLyyYaFZSo8p10CSgAA0cB16qr6C_So18stU24C10Foundation3URLVtXEfU_Tf1cn_nTY0_ + 1104
PROBE     31  PrivacyBrowser                      0x0000000104206e2d $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TQ5_ + 1
PROBE     32  PrivacyBrowser                      0x000000010420cd69 $s14PrivacyBrowser20SafariFrameworkProbeO5start9argumentsySaySSG_tFZyyYacfU0_TATQ0_ + 1
PROBE     33  PrivacyBrowser                      0x00000001042b67c1 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TQ0_ + 1
PROBE     34  PrivacyBrowser                      0x00000001042b6815 $sxIeAgHr_xs5Error_pIegHrzo_s8SendableRzs5NeverORs_r0_lTRyt_Tg5TATQ0_ + 1
PROBE     35  libswift_Concurrency.dylib          0x000000026c71e83d _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1
PROBE   -window raised NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value; caught, so the attempt ends and the process does not
PROBE   giving up; the in-process web view path remains
PROBE RESULT no window
PROBE activation policy afterwards: 0 (0 = regular, 1 = accessory)
PROBE FALLBACK in-process window: visible=true url=https://example.com/ title=Example Domain
PROBE wrote fallback-window.png (15340 bytes)
PROBE wrote fallback-page.png (76051 bytes)
PROBE step window finished
2026-10-29 08:20:23.105 PrivacyBrowser[3372:15838] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:23.106 PrivacyBrowser[3372:15838] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari' (no such file))
2026-10-29 08:20:23.106 PrivacyBrowser[3372:15838] SafariLoader: /System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:23.106 PrivacyBrowser[3372:15838] SafariLoader: /System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari -> nil (on disk: false, dlerror: dlopen(/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari, 0x0006): tried: '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Volumes/Preboot/Cryptexes/OS/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file), '/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari' (no such file))
2026-10-29 08:20:23.117 PrivacyBrowser[3372:15838] SafariLoader: opened /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari (not on disk: resolved from the shared cache)
2026-10-29 08:20:23.117 PrivacyBrowser[3372:15838] SafariWindow: +[BrowserDocumentController sharedDocumentController]: sharedDocumentController -> BrowserDocumentController
2026-10-29 08:20:23.117 PrivacyBrowser[3372:15838] SafariWindow: +sharedDocumentController is now BrowserDocumentController
2026-10-29 08:20:23.270 PrivacyBrowser[3372:15838] SafariWindow[65500C99]: framework image: /System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari
2026-10-29 08:20:23.270 PrivacyBrowser[3372:15838] SafariWindow[65500C99]: document controller: BrowserDocumentController
2026-10-29 08:20:23.270 PrivacyBrowser[3372:15838] SafariWindow[65500C99]: popup path, popup
2026-10-29 08:20:23.270 PrivacyBrowser[3372:15838] SafariWindow[65500C99]: NSApplicationCrashOnExceptions: reads false; arguments NO, app 1, registered unset
2026-10-29 08:20:23.270 PrivacyBrowser[3372:15838] SafariHooks: bound +[WKWebsiteDataStore _safari_dataStoreForProfileWithIdentifier:createIfNecessary:cacheNewDataStoreInMemory:]
2026-10-29 08:20:23.270 PrivacyBrowser[3372:15838] SafariHooks: bound -[WKWebViewConfiguration websiteDataStore]
2026-10-29 08:20:23.271 PrivacyBrowser[3372:15838] SafariWindow[65500C99]: [[BrowserWindowController alloc] initAsPopupWindow:YES]: initAsPopupWindow: -> BrowserWindowController
2026-10-29 08:20:23.271 PrivacyBrowser[3372:15838] SafariWindow[65500C99]: popup controller: BrowserWindowController; isPopupWindow=true, isWindowLoaded=false
2026-10-29 08:20:23.271 PrivacyBrowser[3372:15838] SafariWindow[65500C99]: isPopupWindowUnifiedFieldVisible=false, isWindowLoaded=false
2026-10-29 08:20:23.500 PrivacyBrowser[3372:15838] SafariWindow[65500C99]: RAISED NSInvalidArgumentException: NSConcreteMutableAttributedString addAttribute:value:range:: nil value
2026-10-29 08:20:23.501 PrivacyBrowser[3372:15838] SafariWindow[65500C99]:   0   CoreFoundation                      0x00000001840878a0 __exceptionPreprocess + 176
2026-10-29 08:20:23.501 PrivacyBrowser[3372:15838] SafariWindow[65500C99]:   1   PrivacyBrowser                      0x00000001040e9498 PBPreprocessException + 52
2026-10-29 08:20:23.501 PrivacyBrowser[3372:15838] SafariWindow[65500C99]:   2   libobjc.A.dylib                     0x0000000183b4ab90 objc_exception_throw + 88
2026-10-29 08:20:23.501 PrivacyBrowser[3372:15838] SafariWindow[65500C99]:   3   Foundation                          0x0000000185601444 -[NSConcreteMutableAttributedString attribute:atIndex:effectiveRange:] + 0
2026-10-29 08:20:23.501 PrivacyBrowser[3372:15838] SafariWindow[65500C99]:   4   Safari                              0x00000001b6d56810 -[UnifiedField _notSecureAnnotation] + 364
2026-10-29 08:20:23.501 PrivacyBrowser[3372:15838] SafariWindow[65500C99]:   5   Safari                              0x00000001b6d62bf0 -[UnifiedField _layOutFaviconAndMainContentView] + 2288
2026-10-29 08:20:23.501 PrivacyBrowser[3372:15838] SafariWindow[65500C99]:   6   Safari                              0x00000001b6d61b38 -[UnifiedField layout] + 56
2026-10-29 08:20:23.501 PrivacyBrowser[3372:15838] SafariWindow[65500C99]:   7   AppKit                              0x0000000188a61b1c ___NSViewLayout_block_invoke + 632
2026-10-29 08:20:23.501 PrivacyBrowser[3372:15838] SafariWindow[65500C99]:   8   AppKit                              0x0000000187f78000 NSPerformVisuallyAtomicChange + 108
2026-10-29 08:20:23.501 PrivacyBrowser[3372:15838] SafariWindow[65500C99]:   9   AppKit                              0x0000000187f7c8d8 _NSViewLayout + 96
2026-10-29 08:20:23.501 PrivacyBrowser[3372:15838] SafariWindow[65500C99]:   10  AppKit          
```
