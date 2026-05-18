package com.anka.clawbot

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.os.Build
import android.telephony.SmsManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.util.TimeZone

class PhoneIntentManager(private val activity: Activity) {

    fun dispatch(action: String, params: Map<String, Any?>): Map<String, Any?> {
        return try {
            when (action) {
                "setAlarm" -> setAlarm(params)
                "openWeb" -> openWeb(params)
                "dialPad" -> dialPad(params)
                "share" -> share(params)
                "mapsNavigate" -> mapsNavigate(params)
                "composeEmail" -> composeEmail(params)
                "openCamera" -> openCamera()
                "addCalendarEventIntent" -> addCalendarEventIntent(params)
                "insertCalendarEvent" -> insertCalendarEvent(params)
                "listCalendarEvents" -> listCalendarEvents(params)
                "listContacts" -> listContacts(params)
                "callPhone" -> callPhone(params)
                "sendSms" -> sendSms(params)
                else -> error("Unknown action: $action")
            }
        } catch (e: SecurityException) {
            mapOf("ok" to false, "error" to "permission_denied", "message" to (e.message ?: "denied"))
        } catch (e: Exception) {
            mapOf("ok" to false, "error" to "exception", "message" to (e.message ?: "error"))
        }
    }

    private fun startActivityChecked(intent: Intent): Map<String, Any?> {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return if (intent.resolveActivity(activity.packageManager) != null) {
            activity.startActivity(intent)
            mapOf("ok" to true)
        } else {
            mapOf("ok" to false, "error" to "no_handler", "message" to "No app can handle this intent")
        }
    }

    // ── L1: no-permission actions ──────────────────────────────────

    private fun setAlarm(p: Map<String, Any?>): Map<String, Any?> {
        val hour = (p["hour"] as? Number)?.toInt() ?: error("hour required")
        val minutes = (p["minutes"] as? Number)?.toInt() ?: 0
        val message = p["message"] as? String
        val skipUi = (p["skipUi"] as? Boolean) ?: true
        val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
            putExtra(AlarmClock.EXTRA_HOUR, hour)
            putExtra(AlarmClock.EXTRA_MINUTES, minutes)
            putExtra(AlarmClock.EXTRA_SKIP_UI, skipUi)
            if (message != null) putExtra(AlarmClock.EXTRA_MESSAGE, message)
        }
        return startActivityChecked(intent)
    }

    private fun openWeb(p: Map<String, Any?>): Map<String, Any?> {
        val url = p["url"] as? String ?: error("url required")
        if (!url.startsWith("http://") && !url.startsWith("https://")) {
            return mapOf("ok" to false, "error" to "invalid_url")
        }
        return startActivityChecked(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
    }

    private fun dialPad(p: Map<String, Any?>): Map<String, Any?> {
        val number = validatePhoneNumber(p["number"] as? String ?: error("number required"))
        return startActivityChecked(Intent(Intent.ACTION_DIAL, Uri.parse("tel:$number")))
    }

    private fun share(p: Map<String, Any?>): Map<String, Any?> {
        val text = p["text"] as? String ?: error("text required")
        val subject = p["subject"] as? String
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
            if (subject != null) putExtra(Intent.EXTRA_SUBJECT, subject)
        }
        return startActivityChecked(Intent.createChooser(intent, "Share").apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        })
    }

    private fun mapsNavigate(p: Map<String, Any?>): Map<String, Any?> {
        val query = p["query"] as? String ?: error("query required")
        val uri = Uri.parse("geo:0,0?q=${Uri.encode(query)}")
        return startActivityChecked(Intent(Intent.ACTION_VIEW, uri))
    }

    private fun composeEmail(p: Map<String, Any?>): Map<String, Any?> {
        val to = p["to"] as? String
        val subject = p["subject"] as? String
        val body = p["body"] as? String
        val intent = Intent(Intent.ACTION_SENDTO).apply {
            data = Uri.parse("mailto:")
            if (to != null) putExtra(Intent.EXTRA_EMAIL, arrayOf(to))
            if (subject != null) putExtra(Intent.EXTRA_SUBJECT, subject)
            if (body != null) putExtra(Intent.EXTRA_TEXT, body)
        }
        return startActivityChecked(intent)
    }

    private fun openCamera(): Map<String, Any?> {
        return startActivityChecked(Intent("android.media.action.STILL_IMAGE_CAMERA"))
    }

    private fun addCalendarEventIntent(p: Map<String, Any?>): Map<String, Any?> {
        val title = p["title"] as? String ?: error("title required")
        val begin = (p["beginMillis"] as? Number)?.toLong()
        val end = (p["endMillis"] as? Number)?.toLong()
        val location = p["location"] as? String
        val description = p["description"] as? String
        val intent = Intent(Intent.ACTION_INSERT).apply {
            data = CalendarContract.Events.CONTENT_URI
            putExtra(CalendarContract.Events.TITLE, title)
            if (begin != null) putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, begin)
            if (end != null) putExtra(CalendarContract.EXTRA_EVENT_END_TIME, end)
            if (location != null) putExtra(CalendarContract.Events.EVENT_LOCATION, location)
            if (description != null) putExtra(CalendarContract.Events.DESCRIPTION, description)
        }
        return startActivityChecked(intent)
    }

    // ── Phone number validation ─────────────────────────────────────

    private fun validatePhoneNumber(number: String): String {
        // Strip everything except digits, allow at most one leading +
        val digits = number.replace(Regex("[^0-9]"), "")
        val hasPlus = number.trimStart().startsWith("+")
        val cleaned = if (hasPlus) "+$digits" else digits
        if (digits.length < 3 || digits.length > 15) error("Invalid phone number length")
        return cleaned
    }

    // ── L2: dangerous permissions, requested at use time ───────────
    //
    // Permission flow: ensurePermission() calls ActivityCompat.requestPermissions()
    // which is fire-and-forget from the native side. When a permission is not yet
    // granted, the function returns a map with "error" = "permission_required".
    // The Dart/Flutter side should show an appropriate message and retry the call
    // after the user grants the permission in the system dialog.

    private fun ensurePermission(perm: String): Boolean {
        if (ContextCompat.checkSelfPermission(activity, perm) == PackageManager.PERMISSION_GRANTED) return true
        ActivityCompat.requestPermissions(activity, arrayOf(perm), PERMISSION_REQUEST)
        return false
    }

    private fun insertCalendarEvent(p: Map<String, Any?>): Map<String, Any?> {
        if (!ensurePermission(Manifest.permission.WRITE_CALENDAR)) {
            return mapOf("ok" to false, "error" to "permission_required", "permission" to "WRITE_CALENDAR",
                "message" to "Permission requested. Please grant and retry.")
        }
        val title = p["title"] as? String ?: error("title required")
        val begin = (p["beginMillis"] as? Number)?.toLong() ?: error("beginMillis required")
        val end = (p["endMillis"] as? Number)?.toLong() ?: (begin + 3600_000L)
        val calendarId = (p["calendarId"] as? Number)?.toLong() ?: pickDefaultCalendarId()
        ?: return mapOf("ok" to false, "error" to "no_calendar", "message" to "No calendar account configured")
        val values = ContentValues().apply {
            put(CalendarContract.Events.DTSTART, begin)
            put(CalendarContract.Events.DTEND, end)
            put(CalendarContract.Events.TITLE, title)
            (p["description"] as? String)?.let { put(CalendarContract.Events.DESCRIPTION, it) }
            (p["location"] as? String)?.let { put(CalendarContract.Events.EVENT_LOCATION, it) }
            put(CalendarContract.Events.CALENDAR_ID, calendarId)
            put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
        }
        val uri = activity.contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
        val id = uri?.let { ContentUris.parseId(it) }
        return mapOf("ok" to (id != null), "eventId" to id)
    }

    private fun pickDefaultCalendarId(): Long? {
        val cursor = activity.contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            arrayOf(CalendarContract.Calendars._ID, CalendarContract.Calendars.IS_PRIMARY),
            null, null, null
        ) ?: return null
        cursor.use {
            var fallback: Long? = null
            while (it.moveToNext()) {
                val id = it.getLong(0)
                val primary = it.getInt(1)
                if (primary == 1) return id
                if (fallback == null) fallback = id
            }
            return fallback
        }
    }

    private fun listCalendarEvents(p: Map<String, Any?>): Map<String, Any?> {
        if (!ensurePermission(Manifest.permission.READ_CALENDAR)) {
            return mapOf("ok" to false, "error" to "permission_required", "permission" to "READ_CALENDAR")
        }
        val start = (p["startMillis"] as? Number)?.toLong() ?: System.currentTimeMillis()
        val end = (p["endMillis"] as? Number)?.toLong() ?: (start + 7L * 24 * 3600_000L)
        val limit = (p["limit"] as? Number)?.toInt() ?: 50
        val cursor = activity.contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            arrayOf(
                CalendarContract.Events._ID,
                CalendarContract.Events.TITLE,
                CalendarContract.Events.DTSTART,
                CalendarContract.Events.DTEND,
                CalendarContract.Events.EVENT_LOCATION,
                CalendarContract.Events.DESCRIPTION,
            ),
            "${CalendarContract.Events.DTSTART} >= ? AND ${CalendarContract.Events.DTSTART} <= ?",
            arrayOf(start.toString(), end.toString()),
            "${CalendarContract.Events.DTSTART} ASC"
        ) ?: return mapOf("ok" to false, "error" to "query_failed")
        val events = mutableListOf<Map<String, Any?>>()
        cursor.use {
            while (it.moveToNext() && events.size < limit) {
                events.add(mapOf(
                    "id" to it.getLong(0),
                    "title" to it.getString(1),
                    "beginMillis" to it.getLong(2),
                    "endMillis" to it.getLong(3),
                    "location" to it.getString(4),
                    "description" to it.getString(5),
                ))
            }
        }
        return mapOf("ok" to true, "events" to events)
    }

    private fun listContacts(p: Map<String, Any?>): Map<String, Any?> {
        if (!ensurePermission(Manifest.permission.READ_CONTACTS)) {
            return mapOf("ok" to false, "error" to "permission_required", "permission" to "READ_CONTACTS")
        }
        val query = (p["query"] as? String)?.takeIf { it.isNotBlank() }
        val limit = (p["limit"] as? Number)?.toInt() ?: 50
        val selection: String?
        val selectionArgs: Array<String>?
        if (query != null) {
            selection = "${ContactsContract.Contacts.DISPLAY_NAME} LIKE ?"
            selectionArgs = arrayOf("%$query%")
        } else {
            selection = null; selectionArgs = null
        }
        val cursor = activity.contentResolver.query(
            ContactsContract.Contacts.CONTENT_URI,
            arrayOf(
                ContactsContract.Contacts._ID,
                ContactsContract.Contacts.DISPLAY_NAME,
                ContactsContract.Contacts.HAS_PHONE_NUMBER,
            ),
            selection, selectionArgs,
            "${ContactsContract.Contacts.DISPLAY_NAME} ASC"
        ) ?: return mapOf("ok" to false, "error" to "query_failed")
        val contacts = mutableListOf<Map<String, Any?>>()
        cursor.use {
            while (it.moveToNext() && contacts.size < limit) {
                val id = it.getLong(0)
                val name = it.getString(1) ?: continue
                val hasPhone = it.getInt(2) > 0
                val phones = if (hasPhone) readPhones(id) else emptyList()
                contacts.add(mapOf("id" to id, "name" to name, "phones" to phones))
            }
        }
        return mapOf("ok" to true, "contacts" to contacts)
    }

    private fun readPhones(contactId: Long): List<String> {
        val cursor = activity.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER),
            "${ContactsContract.CommonDataKinds.Phone.CONTACT_ID} = ?",
            arrayOf(contactId.toString()), null
        ) ?: return emptyList()
        val phones = mutableListOf<String>()
        cursor.use { while (it.moveToNext()) phones.add(it.getString(0)) }
        return phones
    }

    // ── L3: high-risk; gated by app-level setting in Dart layer ────

    private fun callPhone(p: Map<String, Any?>): Map<String, Any?> {
        if (!ensurePermission(Manifest.permission.CALL_PHONE)) {
            return mapOf("ok" to false, "error" to "permission_required", "permission" to "CALL_PHONE")
        }
        val number = validatePhoneNumber(p["number"] as? String ?: error("number required"))
        val intent = Intent(Intent.ACTION_CALL, Uri.parse("tel:$number"))
        return startActivityChecked(intent)
    }

    private fun sendSms(p: Map<String, Any?>): Map<String, Any?> {
        if (!ensurePermission(Manifest.permission.SEND_SMS)) {
            return mapOf("ok" to false, "error" to "permission_required", "permission" to "SEND_SMS")
        }
        val number = validatePhoneNumber(p["number"] as? String ?: error("number required"))
        val body = p["body"] as? String ?: error("body required")
        val sm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            activity.getSystemService(SmsManager::class.java)!!
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }
        val parts = sm.divideMessage(body)
        sm.sendMultipartTextMessage(number, null, parts, null, null)
        return mapOf("ok" to true, "parts" to parts.size)
    }

    companion object {
        const val PERMISSION_REQUEST = 2001
    }
}
