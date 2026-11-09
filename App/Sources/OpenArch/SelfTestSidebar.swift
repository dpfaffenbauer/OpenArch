import AppKit
import OpenArchCore

/// Checks for the sidebar's details from Arc: the unread dot and the
/// calendar's date, selecting several rows, the folder preview, the
/// profile over a space's name, „Spaces verwalten“ and Peek on ⇧-click.
/// `--selftest --sidebar-test` runs only these.
extension SelfTest {
    func sidebarDetails(then done: @escaping () -> Void) {
        unreadTest()
        selectionTest()
        profileIndicatorTest()
        manageSpacesTest()
        folderPreviewTest {
            self.multiDragTest {
                self.peekShiftClickTest(then: done)
            }
        }
    }

    /// Gmail, X and Slack count what is unread in their titles; a dot shows
    /// on their favorites and pinned tabs, not on other sites or today tabs.
    private func unreadTest() {
        expect(UnreadBadges.count(inTitle: "Posteingang (3) - jemand@example.com - Gmail") == 3
               && UnreadBadges.count(inTitle: "(12) Startseite / X") == 12
               && UnreadBadges.count(inTitle: "* Slack | allgemein | Firma") == 1
               && UnreadBadges.count(inTitle: "Posteingang - Gmail") == nil
               && UnreadBadges.count(inTitle: "(0) WhatsApp") == nil,
               "page titles report unread counts: Gmail (3), X (12), Slack *")
        expect(UnreadBadges.countsUnread("https://mail.google.com/mail/u/0/#inbox")
               && UnreadBadges.countsUnread("https://www.linkedin.com/feed/")
               && !UnreadBadges.countsUnread("https://de.wikipedia.org/wiki/Matrix_(Film)"),
               "only sites that count unread items in their title get a dot")
        let favorites = library.profile(id: browser.state.space.profileID).favorites
        let gmail = Item.tab(url: "https://mail.google.com/mail/u/0/", title: "Gmail")
        favorites.insert(gmail)
        gmail.liveTitle = "Posteingang (3) - jemand@example.com - Gmail"
        let today = Item.tab(url: "https://mail.google.com/mail/u/1/")
        browser.state.space.today.insert(today)
        today.liveTitle = "Posteingang (5) - Gmail"
        expect(gmail.unreadCount == 3 && today.unreadCount == nil,
               "a Gmail favorite shows a dot for its 3 unread mails; a today tab does not (\(String(describing: gmail.unreadCount)))")
        gmail.liveTitle = nil
        expect(gmail.unreadCount == nil, "a favorite that is not loaded shows no old count")
        expect(UnreadBadges.isCalendar("https://calendar.google.com/calendar/u/0/r")
               && !UnreadBadges.isCalendar("https://www.google.com/"),
               "Google Calendar gets today's date as its icon")
        gmail.detach()
        today.detach()
    }

    /// ⇧-click selects a range, ⌘⇧-click (or ⌘-click with a selection)
    /// one more row; plain ⌘-click still loads in the background. The
    /// selection copies its URLs, goes into a new folder and is archived.
    private func selectionTest() {
        let today = browser.state.space.today
        let tabs = (1...4).map { Item.tab(url: "https://example.com/auswahl\($0)", title: "Auswahl \($0)") }
        for tab in tabs.reversed() { today.insert(tab, at: 0) }
        let shown = browser.state.activeItem

        browser.click(tabs[3], modifiers: .command)
        expect(tabs[3].pane != nil && browser.state.activeItem === shown && browser.state.selection.isEmpty,
               "⌘-click without a selection still loads the tab in the background")
        browser.unload(tabs[3])

        browser.state.selectionAnchorID = tabs[0].id
        browser.click(tabs[2], modifiers: .shift)
        expect(browser.selectedItems.map(\.id) == tabs[0...2].map(\.id) && browser.state.activeItem === shown,
               "⇧-click selects the rows from the last one clicked to this one (\(browser.selectedItems.count))")
        browser.click(tabs[1], modifiers: [.command, .shift])
        expect(browser.selectedItems.map(\.id) == [tabs[0].id, tabs[2].id], "⌘⇧-click takes a row out of the selection")
        browser.click(tabs[3], modifiers: .command)
        expect(browser.selectedItems.map(\.id) == [tabs[0].id, tabs[2].id, tabs[3].id] && tabs[3].pane == nil,
               "⌘-click while rows are selected adds one instead of loading it")
        expect(browser.actsOnSelection(tabs[2]) && !browser.actsOnSelection(tabs[1]),
               "the menu of a selected row acts on the whole selection")

        copyPasteboard.clearContents()
        browser.copyURL()
        let copied = copyPasteboard.string(forType: .string) ?? ""
        expect(copied == [0, 2, 3].map { tabs[$0].currentURL }.joined(separator: "\n"),
               "⇧⌘C copies every selected address, one per line")

        let folder = browser.newFolderWithSelection()
        expect(folder?.role == .pinned && folder?.children.map(\.id) == [0, 2, 3].map { tabs[$0].id }
               && tabs[0].role == .pinned && tabs[0].savedURL.hasSuffix("auswahl1") && browser.state.selection.isEmpty
               && browser.state.renamingItemID == folder?.id,
               "„Neuer Ordner mit 3 Tabs“ pins the selection in a new folder, ready to be named")
        browser.state.renamingItemID = nil
        if let folder {
            for tab in folder.children { browser.unload(tab) }
            folder.detach()
        }

        // A plain click ends the selection.
        browser.state.selectionAnchorID = tabs[1].id
        browser.click(tabs[1], modifiers: .shift)
        expect(browser.selectedItems.count == 1, "⇧-click on the anchor selects that row")
        let archived = library.archive.count
        let count = browser.archiveSelection()
        expect(count == 1 && tabs[1].container == nil && library.archive.count == archived + 1
               && library.archive.first?.url == tabs[1].currentURL,
               "archiving the selection closes its tabs into the archive")
        let other = Item.tab(url: "https://example.com/auswahl5")
        today.insert(other)
        browser.state.selection = [other.id]
        browser.click(other, modifiers: [])
        expect(browser.state.selection.isEmpty && browser.state.activeItem === other, "a plain click ends the selection")
        browser.close(other)
        if let shown { browser.select(shown) }
    }

    /// Several selected rows dragged together land together, in order.
    private func multiDragTest(then done: @escaping () -> Void) {
        let today = browser.state.space.today
        let tabs = (1...3).map { Item.tab(url: "https://example.com/ziehen\($0)", title: "Ziehen \($0)") }
        for tab in tabs.reversed() { today.insert(tab, at: 0) }
        guard let target = browser.state.space.pinned.items.last else {
            expect(false, "a pinned row to drop on")
            return done()
        }
        browser.state.selection = [tabs[0].id, tabs[2].id]
        let provider = browser.dragProvider(for: tabs[2])
        browser.handleDrop([provider], target: .after(target))
        eventually({ tabs[0].role == .pinned && tabs[2].role == .pinned }) { moved in
            let pinned = self.browser.state.space.pinned.items
            let index = pinned.firstIndex { $0 === target } ?? -9
            self.expect(moved && tabs[1].role == .today && pinned.count > index + 2
                        && pinned[index + 1] === tabs[0] && pinned[index + 2] === tabs[2]
                        && self.browser.state.selection.isEmpty,
                        "dragging selected rows moves all of them, in their order")
            for tab in tabs { tab.detach() }
            done()
        }
    }

    /// Resting on a closed folder shows a list of its tabs to search; a
    /// click opens one without opening the folder.
    private func folderPreviewTest(then done: @escaping () -> Void) {
        guard let folder = browser.state.space.pinned.items.first(where: { $0.kind == .folder }) else {
            expect(false, "a pinned folder for the preview")
            return done()
        }
        folder.isExpanded = false
        let entries = FolderPreview.entries(in: folder)
        expect(entries.count == 2 && FolderPreview.filter(entries, "kunden").map(\.displayTitle) == ["Kundenportal"]
               && FolderPreview.filter(entries, "example.net board").count == 1,
               "the preview lists the folder's tabs, subfolders too, and finds them by title and address")
        browser.hoverFolder(folder, inside: true)
        after(0.2) {
            self.expect(self.browser.state.folderPreviewID == nil, "the preview waits a moment (0.45 s)")
        }
        after(0.8) {
            self.expect(self.browser.state.folderPreviewID == folder.id, "resting on a closed folder shows its tabs")
            guard let tab = entries.first(where: { $0.displayTitle == "Kundenportal" }) else { return done() }
            self.browser.openFromFolderPreview(tab)
            self.expect(self.browser.state.activeItem === tab && !folder.isExpanded && self.browser.state.folderPreviewID == nil,
                        "a click in the preview opens the tab and leaves the folder closed")
            folder.isExpanded = true
            self.browser.hoverFolder(folder, inside: true)
            after(0.6) {
                self.expect(self.browser.state.folderPreviewID == nil, "an open folder shows no preview")
                done()
            }
        }
    }

    /// The profile and its Google account over the space's name; a ring in
    /// the profile's color around the space's icon.
    private func profileIndicatorTest() {
        let answer = #")]}'\#n["gaia.l.a.r",[["gaia.l.a",1,"Erika Muster","erika@example.com","https://lh3.googleusercontent.com/a/photo",1,1,0,null,1,"1234",null,null,null,null,1],["gaia.l.a",1,"Alt","alt@example.com","",1,0,0,null,0,"5678"]]]"#
        let accounts = GoogleAccounts.accounts(fromListAccounts: answer)
        expect(accounts == [GoogleAccounts.Account(name: "Erika Muster", email: "erika@example.com",
                                                   photoURL: "https://lh3.googleusercontent.com/a/photo")],
               "Google's list of accounts gives the signed-in one, with name, email and picture")
        expect(GoogleAccounts.accounts(fromListAccounts: "[\"gaia.l.a.r\",[]]") == []
               && GoogleAccounts.accounts(fromListAccounts: "<html>Anmelden</html>") == nil,
               "nobody signed in, and a page that is not the list, are told apart")
        let profiles = library.profiles
        expect(profiles.count > 1 && library.color(for: profiles[0]).hexString != library.color(for: profiles[1]).hexString,
               "each profile has a color of its own for the ring")
        let profileID = browser.state.space.profileID
        GoogleAccounts.shared.refresh(profileID)
        expect(GoogleAccounts.shared.state(for: profileID) == nil, "the self-test never asks Google")
        GoogleAccounts.shared.setForTesting(.accounts(accounts ?? []), profileID: profileID)
        expect(GoogleAccounts.shared.state(for: profileID) == .accounts(accounts ?? []),
               "the card over the space's name shows the profile's Google account")
        GoogleAccounts.shared.setForTesting(nil, profileID: profileID)
    }

    /// „Spaces verwalten“: a card over the page; sorting, and deleting with
    /// a question that says where the tabs go.
    private func manageSpacesTest() {
        let manage = browser.manageSpaces
        manage.show()
        expect(manage.isOpen, "„Spaces verwalten …“ opens a card over the page")
        let order = library.spaces.map(\.id)
        library.moveSpaces(fromOffsets: IndexSet(integer: order.count - 1), toOffset: 0)
        expect(library.spaces.first?.id == order.last, "dragging a row sorts the spaces")
        library.moveSpaces(fromOffsets: IndexSet(integer: 0), toOffset: order.count)
        expect(library.spaces.map(\.id) == order, "and back")

        let space = library.addSpace(name: "Wegwerf", profileID: browser.state.space.profileID)
        space.pinned.insert(Item.folder("Ordner", children: [Item.tab(url: "https://example.com/weg-pinned")]))
        space.today.insert(Item.tab(url: "https://example.com/weg-offen"))
        let message = browser.deleteSpaceMessage(space)
        expect(message.contains("1 Tab angeheftet (in 1 Ordner)") && message.contains("1 Tab offen")
               && message.contains("ins Archiv"),
               "deleting a space says what happens to its tabs (\(message))")
        browser.removeSpace(space)
        expect(!library.spaces.contains { $0 === space } && library.archive.prefix(2).map(\.url).contains("https://example.com/weg-offen"),
               "a deleted space's tabs go into the archive")
        manage.hide()
        expect(!manage.isOpen, "the card closes")
    }

    /// ⇧-click on any link opens Peek; ⌘Z right after closing it, and
    /// ⇧⌘T, open it again; with Peek off it is a new tab.
    private func peekShiftClickTest(then done: @escaping () -> Void) {
        let tab = browser.openInNewTab("https://example.com/")
        let peek = browser.peek
        after(3) {
            tab.pane?.executeJavaScript(
                "document.querySelector('a[href]').dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, shiftKey: true, view: window}))",
                userGesture: true)
        }
        after(5) {
            self.expect(peek.isOpen && peek.model.url.contains("iana.org") && tab.currentURL.contains("example.com"),
                        "⇧-click on a link in a today tab opens it in Peek (\(peek.model.url))")
            if !peek.isOpen { peek.open("https://www.iana.org/", from: tab) }
            let url = peek.model.url
            peek.close()
            let undo = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                        windowNumber: self.browser.window?.windowNumber ?? 0, context: nil,
                                        characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)
            if let undo {
                let reopened = peek.handleUndoKey(undo)
                self.expect(reopened && peek.isOpen && peek.model.url == url, "⌘Z right after closing Peek opens it again")
            }
            peek.close()
            if let app = NSApp.delegate as? AppDelegate {
                app.reopenTab(nil)
                self.expect(peek.isOpen && peek.model.url == url, "⇧⌘T opens a Peek closed after the last tab again")
            }
            peek.close()
            let other = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                         isARepeat: false, keyCode: 0)
            if let other, let undo {
                _ = peek.handleUndoKey(other)
                self.expect(!peek.handleUndoKey(undo) && !peek.isOpen,
                            "after another key ⌘Z is the page's undo again")
                peek.close()
            }
            self.library.settings.peek = false
            let taken = (tab.pane as? OACPane).map { self.browser.pane($0, wantsPeekWithURL: "https://www.iana.org/") } ?? true
            self.expect(!taken && !peek.isOpen, "with Peek off a ⇧-click opens a new tab instead")
            self.library.settings.peek = true
            self.browser.close(tab)
            done()
        }
    }
}
