package com.real.drama.compose

import org.json.JSONObject

val followLabels = linkedMapOf("planned" to "想看", "watching" to "在看", "watched" to "已看")
fun observedFollow(previous: JSONObject?, drama: Drama, episode: Int = 0, position: Double = 0.0, duration: Double = 0.0): JSONObject {
    val count = maxOf(previous?.optInt("knownEpisodes") ?: 0, drama.json.optInt("episodes"))
    val next = previous?.copy() ?: obj("status" to "planned", "manuallyWatched" to false, "readEpisodes" to count.takeIf { it > 0 })
    if (!next.optBoolean("manuallyWatched")) {
        if (next.text("status") == "watched" && count > next.optInt("knownEpisodes")) next.put("status", "watching")
        if (position > 0) next.put("status", if (count > 0 && episode >= count && duration > 1 && position >= duration - 1) "watched" else "watching")
    }
    if (next.isNull("readEpisodes") && count > 0) next.put("readEpisodes", count)
    return next.put("knownEpisodes", count)
}
suspend fun LocalStore.followStatus(drama: Drama, status: String) {
    require(status in followLabels); val expected = epoch
    update { next ->
        check(epoch == expected && allowed(drama.source))
        val rows = list("favorites").objects()
        if (rows.none { it.text("id") == drama.id }) { require(rows.size < 20000); next.put(key("favorites"), org.json.JSONArray(rows + drama.json).toString()) }
        val states = json("followStates")
        val state = observedFollow(states.optJSONObject(drama.id), drama).put("status", status).put("manuallyWatched", status == "watched")
        if (status == "watched" && state.optInt("knownEpisodes") > 0) state.put("readEpisodes", state.optInt("knownEpisodes"))
        states.put(drama.id, state); next.put(key("followStates"), states.toString())
    }
}
