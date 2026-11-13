package xyz.vidur.pux.service

import xyz.vidur.pux.api.ApiClient
import xyz.vidur.pux.storage.RecordStore

/** DELETE endpoints are idempotent; retain intent until local forget has completed. */
internal class RemoteRemoval(private val store: RecordStore, private val api: ApiClient) {
    suspend fun removeDevice(recordId: String, deviceId: String) {
        store.beginRemoteRemoval("remove_device")
        api.deleteDevice(recordId, deviceId)
    }

    suspend fun deleteRelay(recordId: String) {
        store.beginRemoteRemoval("delete_relay")
        api.deleteRecord(recordId)
    }
}
