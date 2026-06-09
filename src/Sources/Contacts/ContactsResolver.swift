import Foundation
import Contacts

/// Maps an iMessage *handle* (phone number in E.164 or an email
/// address) to a human-friendly display name from the user's local
/// Contacts database.
///
/// Resolution is best-effort: if the user hasn't granted Contacts
/// permission, or there's simply no contact card for the given handle,
/// `name(for:)` returns `nil` and the caller should fall back to the
/// raw handle. The resolver never raises and never blocks the event
/// pipeline.
///
/// Lookups are cached in-memory for the lifetime of the process so
/// the chat.db watcher doesn't issue a `CNContactStore` query for
/// every reaction tap on a busy thread. The cache uses the raw handle
/// (post-normalization) as the key so reflected lookups stay cheap.
final class ContactsResolver: @unchecked Sendable {
    private let store = CNContactStore()
    private let cacheLock = NSLock()
    private var cache: [String: String?] = [:]

    /// Returns the granted/denied/notDetermined state at construction
    /// time. The app uses this to drive the optional Settings UI and
    /// the friendly first-launch prompt.
    static func authorizationStatus() -> CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    /// Asks the user for Contacts permission. Idempotent — calling
    /// after a previous grant returns immediately with `true`. After
    /// a previous deny it returns `false` without re-prompting (TCC
    /// suppresses the dialog).
    @discardableResult
    func requestAccess() async -> Bool {
        let status = Self.authorizationStatus()
        if status == .authorized { return true }
        if status == .denied || status == .restricted { return false }
        return await withCheckedContinuation { cont in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    Log.contacts.error("CNContactStore.requestAccess error: \(error.localizedDescription, privacy: .public)")
                }
                cont.resume(returning: granted)
            }
        }
    }

    /// Look up a display name for a handle.
    ///
    /// - Phone-number handles are matched via
    ///   `CNContact.predicateForContacts(matching: CNPhoneNumber)`,
    ///   which leverages the system's E.164-aware matcher (handles
    ///   minor formatting variations transparently).
    /// - Email handles are matched via
    ///   `predicateForContacts(matchingEmailAddress:)`.
    /// - Returns `nil` for an empty / unknown / unauthorized handle.
    ///
    /// Safe to call from any thread.
    func name(for handle: String) -> String? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard Self.authorizationStatus() == .authorized else { return nil }

        cacheLock.lock()
        if let cached = cache[trimmed] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let resolved = lookup(handle: trimmed)
        cacheLock.lock()
        cache[trimmed] = resolved
        cacheLock.unlock()
        return resolved
    }

    /// Invalidate the cache. Called when the OS broadcasts
    /// `CNContactStoreDidChange` so a freshly-added card is picked
    /// up without restarting the app.
    func invalidate() {
        cacheLock.lock()
        cache.removeAll(keepingCapacity: true)
        cacheLock.unlock()
    }

    private func lookup(handle: String) -> String? {
        let predicate: NSPredicate
        if handle.contains("@") {
            predicate = CNContact.predicateForContacts(matchingEmailAddress: handle)
        } else {
            predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: handle))
        }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]

        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            guard let contact = contacts.first else { return nil }
            if let full = CNContactFormatter.string(from: contact, style: .fullName), !full.isEmpty {
                return full
            }
            let nick = contact.nickname.trimmingCharacters(in: .whitespaces)
            if !nick.isEmpty { return nick }
            let org = contact.organizationName.trimmingCharacters(in: .whitespaces)
            if !org.isEmpty { return org }
            return nil
        } catch {
            // CNError 102 ("unauthorized") shows up here if the user
            // revokes access mid-run; we want to swallow it and just
            // serve `nil` so the relay keeps moving.
            Log.contacts.debug("contact lookup failed for handle: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
