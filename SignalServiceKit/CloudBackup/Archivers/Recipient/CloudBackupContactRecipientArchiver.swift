//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

/**
 * Archives a contact (``SignalRecipient``) as a ``BackupProtoContact``, which is a type of
 * ``BackupProtoRecipient``.
 */
public class CloudBackupContactRecipientArchiver: CloudBackupRecipientDestinationArchiver {

    private let blockingManager: CloudBackup.Shims.BlockingManager
    private let profileManager: CloudBackup.Shims.ProfileManager
    private let recipientHidingManager: RecipientHidingManager
    private let recipientStore: SignalRecipientStore
    private let storyStore: StoryStore
    private let tsAccountManager: TSAccountManager

    public init(
        blockingManager: CloudBackup.Shims.BlockingManager,
        profileManager: CloudBackup.Shims.ProfileManager,
        recipientHidingManager: RecipientHidingManager,
        recipientStore: SignalRecipientStore,
        storyStore: StoryStore,
        tsAccountManager: TSAccountManager
    ) {
        self.blockingManager = blockingManager
        self.profileManager = profileManager
        self.recipientHidingManager = recipientHidingManager
        self.recipientStore = recipientStore
        self.storyStore = storyStore
        self.tsAccountManager = tsAccountManager
    }

    private typealias ArchivingAddress = CloudBackup.RecipientArchivingContext.Address

    public func archiveRecipients(
        stream: CloudBackupProtoOutputStream,
        context: CloudBackup.RecipientArchivingContext,
        tx: DBReadTransaction
    ) -> ArchiveMultiFrameResult {
        let whitelistedAddresses = Set(profileManager.allWhitelistedRegisteredAddresses(tx: tx))
        let blockedAddresses = blockingManager.blockedAddresses(tx: tx)

        var errors = [ArchiveMultiFrameResult.Error]()

        recipientStore.enumerateAll(tx: tx) { recipient in
            guard
                let recipientAddress = CloudBackup.ContactAddress(
                    aci: recipient.aci,
                    pni: recipient.pni,
                    e164: E164(recipient.phoneNumber)
                )?.asArchivingAddress()
            else {
                // Skip but don't add to the list of errors.
                Logger.warn("Skipping empty recipient")
                return
            }

            let recipientId = context.assignRecipientId(to: recipientAddress)

            let recipientBuilder = BackupProtoRecipient.builder(
                id: recipientId.value
            )

            var unregisteredAtTimestamp: UInt64 = 0
            if !recipient.isRegistered {
                unregisteredAtTimestamp = (
                    recipient.unregisteredAtTimestamp ?? SignalRecipient.Constants.distantPastUnregisteredTimestamp
                )
            }

            let storyContext = recipient.aci.map { self.storyStore.getOrCreateStoryContextAssociatedData(for: $0, tx: tx) }

            let contactBuilder = BackupProtoContact.builder(
                blocked: blockedAddresses.contains(recipient.address),
                hidden: self.recipientHidingManager.isHiddenRecipient(recipient, tx: tx),
                unregisteredTimestamp: unregisteredAtTimestamp,
                profileSharing: whitelistedAddresses.contains(recipient.address),
                hideStory: storyContext?.isHidden ?? false
            )

            contactBuilder.setRegistered(recipient.isRegistered ? .registered : .notRegistered)

            recipient.aci.map(\.rawUUID.data).map(contactBuilder.setAci)
            recipient.pni.map(\.rawUUID.data).map(contactBuilder.setPni)
            recipient.address.e164.map(\.uint64Value).map(contactBuilder.setE164)
            // TODO: username?

            let profile = self.profileManager.getUserProfile(for: recipient.address, tx: tx)
            profile?.profileKey.map(\.keyData).map(contactBuilder.setProfileKey(_:))
            profile?.unfilteredGivenName.map(contactBuilder.setProfileGivenName(_:))
            profile?.unfilteredFamilyName.map(contactBuilder.setProfileFamilyName(_:))
            // TODO: joined name?

            Self.writeFrameToStream(stream, frameBuilder: { frameBuilder in
                let contact = try contactBuilder.build()
                recipientBuilder.setContact(contact)
                let protoRecipient = try recipientBuilder.build()
                frameBuilder.setRecipient(protoRecipient)
                return try frameBuilder.build()
            }).map { errors.append($0.asArchiveFramesError(objectId: recipientId)) }
        }

        if errors.isEmpty {
            return .success
        } else {
            return .partialSuccess(errors)
        }
    }

    static func canRestore(_ recipient: BackupProtoRecipient) -> Bool {
        return recipient.contact != nil
    }

    public func restore(
        _ recipientProto: BackupProtoRecipient,
        context: CloudBackup.RecipientRestoringContext,
        tx: DBWriteTransaction
    ) -> RestoreFrameResult {
        guard let contactProto = recipientProto.contact else {
            owsFail("Invalid proto for class")
        }

        let isRegistered: Bool?
        let unregisteredTimestamp: UInt64?
        switch contactProto.registered {
        case .none, .unknown:
            isRegistered = nil
            unregisteredTimestamp = nil
        case .registered:
            isRegistered = true
            unregisteredTimestamp = nil
        case .notRegistered:
            isRegistered = false
            unregisteredTimestamp = contactProto.unregisteredTimestamp
        }

        guard let address = contactProto.address else {
            // Need at least one identifier!
            return .failure(recipientProto.recipientId, [.invalidProtoData])
        }
        context[recipientProto.recipientId] = .contact(address)

        var recipient = SignalRecipient.fromBackup(
            address,
            isRegistered: isRegistered,
            unregisteredAtTimestamp: unregisteredTimestamp
        )

        // TODO: remove this check; we should be starting with an empty database.
        if let existingRecipient = recipientStore.recipient(for: recipient.address, tx: tx) {
            recipient = existingRecipient
            if isRegistered == true, !recipient.isRegistered {
                recipientStore.markAsRegisteredAndSave(recipient, tx: tx)
            } else if isRegistered == false, recipient.isRegistered, let unregisteredTimestamp {
                recipientStore.markAsUnregisteredAndSave(recipient, at: unregisteredTimestamp, tx: tx)
            }
        } else {
            do {
                try recipientStore.insert(recipient, tx: tx)
            } catch let error {
                return .failure(recipientProto.recipientId, [.databaseInsertionFailed(error)])
            }
        }

        if contactProto.profileSharing {
            // Add to the whitelist.
            profileManager.addToWhitelist(recipient.address, tx: tx)
        }

        if contactProto.blocked {
            blockingManager.addBlockedAddress(recipient.address, tx: tx)
        }

        if contactProto.hidden {
            do {
                try recipientHidingManager.addHiddenRecipient(recipient, wasLocallyInitiated: false, tx: tx)
            } catch let error {
                return .failure(recipientProto.recipientId, [.databaseInsertionFailed(error)])
            }
        }

        // We only need to active hide, since unhidden is the default.
        if contactProto.hideStory, let aci = address.aci {
            let storyContext = storyStore.getOrCreateStoryContextAssociatedData(for: aci, tx: tx)
            storyStore.updateStoryContext(storyContext, isHidden: true, tx: tx)
        }

        profileManager.setProfileGivenName(
            givenName: contactProto.profileGivenName,
            familyName: contactProto.profileFamilyName,
            profileKey: contactProto.profileKey,
            address: recipient.address,
            tx: tx
        )

        return .success
    }
}
