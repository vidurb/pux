package xyz.vidur.pux.service

import xyz.vidur.pux.storage.RecordStore

/** Shared policy for every delivery start / resume / migration-retry entry point. */
object DeliveryStartGate {
    fun mayStart(
        store: RecordStore,
        forgetCleanupPending: Boolean,
        storageUnavailable: Boolean,
        resumeDespitePendingRemoval: Boolean = false,
    ): Boolean {
        if (storageUnavailable) return false
        if (forgetCleanupPending || RecordStore.enrollmentBlocked) return false
        if (!resumeDespitePendingRemoval && store.pendingRemoteRemoval() != null) return false
        if (!store.isEnrolled()) return false
        return true
    }
}
