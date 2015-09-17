/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import XCGLogger

private let log = Logger.syncLogger

class SQLiteBookmarkFolder: BookmarkFolder {
    private let cursor: Cursor<BookmarkNode>
    override var count: Int {
        return cursor.count
    }

    override subscript(index: Int) -> BookmarkNode {
        let bookmark = cursor[index]
        if let item = bookmark as? BookmarkItem {
            return item
        }

        // TODO: this is fragile.
        return bookmark as! BookmarkFolder
    }

    init(guid: String, title: String, children: Cursor<BookmarkNode>) {
        self.cursor = children
        super.init(guid: guid, title: title, editable: false)
    }
}

public class SQLiteBookmarks: BookmarksModelFactory {
    let db: BrowserDB
    let favicons: FaviconsTable<Favicon>

    private static let defaultFolderTitle = NSLocalizedString("Untitled", tableName: "Storage", comment: "The default name for bookmark folders without titles.")
    private static let defaultItemTitle = NSLocalizedString("Untitled", tableName: "Storage", comment: "The default name for bookmark nodes without titles.")

    public init(db: BrowserDB) {
        self.db = db
        self.favicons = FaviconsTable<Favicon>()
    }

    private class func itemFactory(row: SDRow) -> BookmarkItem {
        let id = row["id"] as! Int
        let guid = row["guid"] as! String
        let url = row["url"] as! String
        let title = row["title"] as? String ?? url
        let bookmark = BookmarkItem(guid: guid, title: title, url: url, editable: false)

        // TODO: share this logic with SQLiteHistory.
        if let faviconUrl = row["iconURL"] as? String,
           let date = row["iconDate"] as? Double,
           let faviconType = row["iconType"] as? Int {
            bookmark.favicon = Favicon(url: faviconUrl,
                date: NSDate(timeIntervalSince1970: date),
                type: IconType(rawValue: faviconType)!)
        }

        bookmark.id = id
        return bookmark
    }

    private class func folderFactory(row: SDRow) -> BookmarkFolder {
        let id = row["id"] as! Int
        let guid = row["guid"] as! String
        let title = row["title"] as? String ?? SQLiteBookmarks.defaultFolderTitle
        let folder = BookmarkFolder(guid: guid, title: title, editable: false)
        folder.id = id
        return folder
    }

    private class func nodeFactory(row: SDRow) -> BookmarkNode {
        let guid = row["guid"] as! String
        let title = row["title"] as? String ?? SQLiteBookmarks.defaultItemTitle
        return BookmarkNode(guid: guid, title: title, editable: false)
    }

    private class func factory(row: SDRow) -> BookmarkNode {
        if let typeCode = row["type"] as? Int, type = BookmarkNodeType(rawValue: typeCode) {
            switch type {
            case .Bookmark:
                return itemFactory(row)
            case .Folder:
                return folderFactory(row)
            case .DynamicContainer:
                fallthrough
            case .Separator:
                // TODO
                assert(false, "Separators not yet supported.")
            case .Livemark:
                // TODO
                assert(false, "Livemarks not yet supported.")
            case .Query:
                // TODO
                assert(false, "Queries not yet supported.")
            }
        }

        assert(false, "Invalid bookmark data.")
        return nodeFactory(row)
    }

    private func getChildrenWhere(whereClause: String, args: Args, includeIcon: Bool) -> Cursor<BookmarkNode> {
        var err: NSError? = nil
        return db.withReadableConnection(&err) { (conn, err) -> Cursor<BookmarkNode> in
            let inner = "SELECT id, type, guid, url, title, faviconID FROM \(TableBookmarks) WHERE \(whereClause)"

            if includeIcon {
                let sql =
                "SELECT bookmarks.id AS id, bookmarks.type AS type, guid, bookmarks.url AS url, title, " +
                "favicons.url AS iconURL, favicons.date AS iconDate, favicons.type AS iconType " +
                "FROM (\(inner)) AS bookmarks " +
                "LEFT OUTER JOIN favicons ON bookmarks.faviconID = favicons.id"
                return conn.executeQuery(sql, factory: SQLiteBookmarks.factory, withArgs: args)
            } else {
                return conn.executeQuery(inner, factory: SQLiteBookmarks.factory, withArgs: args)
            }
        }
    }

    private func getRootChildren() -> Cursor<BookmarkNode> {
        let args: Args = [BookmarkRoots.RootID, BookmarkRoots.RootID]
        let sql = "parent = ? AND id IS NOT ?"
        return self.getChildrenWhere(sql, args: args, includeIcon: true)
    }

    private func getChildren(guid: String) -> Cursor<BookmarkNode> {
        let args: Args = [guid]
        let sql = "parent IS NOT NULL AND parent = (SELECT id FROM \(TableBookmarks) WHERE guid = ?)"
        return self.getChildrenWhere(sql, args: args, includeIcon: true)
    }

    private func modelForFolder(guid: String, title: String) -> Deferred<Maybe<BookmarksModel>> {
        let children = getChildren(guid)
        if children.status == .Failure {
            return deferMaybe(DatabaseError(description: children.statusMessage))
        }

        let f = SQLiteBookmarkFolder(guid: guid, title: title, children: children)

        // We add some suggested sites to the mobile bookmarks folder.
        if guid == BookmarkRoots.MobileFolderGUID {
            let extended = BookmarkFolderWithDefaults(folder: f, sites: SuggestedSites)
            return deferMaybe(BookmarksModel(modelFactory: self, root: extended))
        } else {
            return deferMaybe(BookmarksModel(modelFactory: self, root: f))
        }
    }

    public func modelForFolder(folder: BookmarkFolder) -> Deferred<Maybe<BookmarksModel>> {
        return self.modelForFolder(folder.guid, title: folder.title)
    }

    public func modelForFolder(guid: String) -> Deferred<Maybe<BookmarksModel>> {
        return self.modelForFolder(guid, title: "")
    }

    public func modelForRoot() -> Deferred<Maybe<BookmarksModel>> {
        let children = getRootChildren()
        if children.status == .Failure {
            return deferMaybe(DatabaseError(description: children.statusMessage))
        }
        let folder = SQLiteBookmarkFolder(guid: BookmarkRoots.RootGUID, title: "Root", children: children)
        return deferMaybe(BookmarksModel(modelFactory: self, root: folder))
    }

    public var nullModel: BookmarksModel {
        let children = Cursor<BookmarkNode>(status: .Failure, msg: "Null model")
        let folder = SQLiteBookmarkFolder(guid: "Null", title: "Null", children: children)
        return BookmarksModel(modelFactory: self, root: folder)
    }

    public func isBookmarked(url: String) -> Deferred<Maybe<Bool>> {
        var err: NSError?
        let sql = "SELECT id FROM \(TableBookmarks) WHERE url = ? LIMIT 1"
        let args: Args = [url]

        let c = db.withReadableConnection(&err) { (conn, err) -> Cursor<Int> in
            return conn.executeQuery(sql, factory: { $0["id"] as! Int }, withArgs: args)
        }

        if c.status == .Success {
            return deferMaybe(c.count > 0)
        }
        return deferMaybe(DatabaseError(err: err))
    }

    public func clearBookmarks() -> Success {
        return self.db.run([
            ("DELETE FROM \(TableBookmarks) WHERE parent IS NOT ?", [BookmarkRoots.RootID]),
            self.favicons.getCleanupCommands()
        ])
    }

    public func removeByURL(url: String) -> Success {
        log.debug("Removing bookmark \(url).")
        return self.db.run([
            ("DELETE FROM \(TableBookmarks) WHERE url = ?", [url]),
        ])
    }

    public func remove(bookmark: BookmarkNode) -> Success {
        if let item = bookmark as? BookmarkItem {
            log.debug("Removing bookmark \(item.url).")
        }

        let sql: String
        let args: Args
        if let id = bookmark.id {
            sql = "DELETE FROM \(TableBookmarks) WHERE id = ?"
            args = [id]
        } else {
            sql = "DELETE FROM \(TableBookmarks) WHERE guid = ?"
            args = [bookmark.guid]
        }

        return self.db.run([
            (sql, args),
        ])
    }
}

extension SQLiteBookmarks: ShareToDestination {
    public func addToMobileBookmarks(url: NSURL, title: String, favicon: Favicon?) -> Success {
        var err: NSError?

        return self.db.withWritableConnection(&err) {  (conn, err) -> Success in
            func insertBookmark(icon: Int) -> Success {
                log.debug("Inserting bookmark with specified icon \(icon).")
                let urlString = url.absoluteString
                var args: Args = [
                    Bytes.generateGUID(),
                    BookmarkNodeType.Bookmark.rawValue,
                    urlString,
                    title,
                    BookmarkRoots.MobileID,
                ]

                // If the caller didn't provide an icon (and they usually don't!),
                // do a reverse lookup in history. We use a view to make this simple.
                let iconValue: String
                if icon == -1 {
                    iconValue = "(SELECT iconID FROM \(ViewIconForURL) WHERE url = ?)"
                    args.append(urlString)
                } else {
                    iconValue = "?"
                    args.append(icon)
                }

                let sql = "INSERT INTO \(TableBookmarks) (guid, type, url, title, parent, faviconID) VALUES (?, ?, ?, ?, ?, \(iconValue))"
                err = conn.executeChange(sql, withArgs: args)
                if let err = err {
                    log.error("Error inserting \(urlString). Got \(err).")
                    return deferMaybe(DatabaseError(err: err))
                }
                return succeed()
            }

            // Insert the favicon.
            if let icon = favicon {
                if let id = self.favicons.insertOrUpdate(conn, obj: icon) {
                	return insertBookmark(id)
                }
            }
            return insertBookmark(-1)
        }
    }

    public func shareItem(item: ShareItem) {
        // We parse here in anticipation of getting real URLs at some point.
        if let url = item.url.asURL {
            let title = item.title ?? url.absoluteString
            self.addToMobileBookmarks(url, title: title, favicon: item.favicon)
        }
    }
}

extension SQLiteBookmarks: SearchableBookmarks {
    public func bookmarksByURL(url: NSURL) -> Deferred<Maybe<Cursor<BookmarkItem>>> {
        let inner = "SELECT id, type, guid, url, title, faviconID FROM \(TableBookmarks) WHERE type = \(BookmarkNodeType.Bookmark.rawValue) AND url = ?"
        let sql =
        "SELECT bookmarks.id AS id, bookmarks.type AS type, guid, bookmarks.url AS url, title, " +
        "favicons.url AS iconURL, favicons.date AS iconDate, favicons.type AS iconType " +
        "FROM (\(inner)) AS bookmarks " +
        "LEFT OUTER JOIN favicons ON bookmarks.faviconID = favicons.id"
        let args: Args = [url.absoluteString]
        return db.runQuery(sql, args: args, factory: SQLiteBookmarks.itemFactory)
    }
}

private extension BookmarkMirrorItem {
    func getUpdateOrInsertArgs() -> Args {
        let args: Args = [
            self.type.rawValue,
            NSNumber(unsignedLongLong: self.serverModified),
            self.isDeleted ? 1 : 0,
            self.hasDupe ? 1 : 0,
            self.parentID,
            self.parentName,
            self.feedURI,
            self.siteURI,
            self.pos,
            self.title,
            self.description,
            self.bookmarkURI,
            self.tags,
            self.keyword,
            self.folderName,
            self.queryID,
            self.guid,
        ]

        return args
    }
}

extension SQLiteBookmarks: BookmarkMirrorStorage {
    public func applyRecords(records: [BookmarkMirrorItem]) -> Success {
        // Within a transaction, we first attempt to update each item.
        // If an update fails, insert instead. TODO: batch the inserts!
        let deferred = Deferred<Maybe<()>>(defaultQueue: dispatch_get_main_queue())

        let values = records.lazy.map { $0.getUpdateOrInsertArgs() }
        var err: NSError?
        self.db.transaction(&err) { (conn, err) -> Bool in
            // These have the same values in the same order.
            let update =
            "UPDATE \(TableBookmarksMirror) SET " +
            "type = ?, server_modified = ?, is_deleted = ?, " +
            "hasDupe = ?, parentid = ?, parentName = ?, " +
            "feedUri = ?, siteUri = ?, pos = ?, title = ?, " +
            "description = ?, bmkUri = ?, tags = ?, keyword = ?, " +
            "folderName = ?, queryId = ? " +
            "WHERE guid = ?"

            let insert =
            "INSERT OR IGNORE INTO \(TableBookmarksMirror) " +
            "(type, server_modified, is_deleted, hasDupe, parentid, parentName, " +
             "feedUri, siteUri, pos, title, description, bmkUri, tags, keyword, folderName, queryId) " +
            "VALUES " +
            "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"

            for args in values {
                if let error = conn.executeChange(update, withArgs: args) {
                    log.error("Updating mirror: \(error.description).")
                    err = error
                    deferred.fill(Maybe(failure: DatabaseError(err: error)))
                    return false
                }

                if conn.numberOfRowsModified > 0 {
                    continue
                }

                if let error = conn.executeChange(insert, withArgs: args) {
                    log.error("Inserting mirror: \(error.description).")
                    err = error
                    deferred.fill(Maybe(failure: DatabaseError(err: error)))
                    return false
                }
            }

            deferred.fillIfUnfilled(Maybe(failure: DatabaseError(err: err)))
            return err == nil
        }

        return deferred
    }
}