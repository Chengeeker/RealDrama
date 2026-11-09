package com.real.drama.compose

import org.json.JSONObject

class MediaProbe(val raw: JSONObject) {
    val video = raw.array("streams").objects().firstOrNull { it.text("codec_type") == "video" } ?: JSONObject()
    val audio = raw.array("streams").objects().firstOrNull { it.text("codec_type") == "audio" } ?: JSONObject()
    val duration = raw.optJSONObject("format")?.optDouble("duration", 0.0) ?: 0.0
    val videoSignature = listOf("codec_name", "width", "height", "pix_fmt").joinToString("|") { video.text(it) } + "|${video.text("sample_aspect_ratio", "1:1")}|${video.text("color_transfer", "unknown")}|${video.text("color_primaries", "unknown")}"
    val audioSignature = if (audio.length() == 0) "none" else listOf("codec_name", "profile", "sample_rate", "channels", "channel_layout", "extradata_hash").joinToString("|") { audio.text(it, if (it in setOf("profile", "extradata_hash")) "unknown" else "") }
}
class MergePlan(probes: List<MediaProbe>) {
    val video: MediaProbe
    val audio: MediaProbe?
    val videoChanges: List<Boolean>
    val audioChanges: List<Boolean>
    val transport: Boolean
    init {
        require(probes.size >= 2 && probes.all { it.video.text("codec_name").isNotEmpty() && it.duration > 0 && it.duration.isFinite() }) { "请至少选择两集完整视频" }
        fun majority(rows: List<MediaProbe>, key: (MediaProbe) -> String) = rows.groupBy(key).values.sortedWith(compareByDescending<List<MediaProbe>> { it.size }.thenByDescending { list -> list.sumOf { it.duration } }).first().first()
        video = majority(probes) { it.videoSignature }
        audio = probes.filter { it.audio.length() > 0 }.takeIf { it.isNotEmpty() }?.let { majority(it) { p -> p.audioSignature } }
        videoChanges = probes.map { it.videoSignature != video.videoSignature }
        val ac = probes.map { audio != null && it.audioSignature != audio.audioSignature }
        audioChanges = if (audio?.audio?.text("codec_name") == "aac" && ac.any { it }) List(probes.size) { true } else ac
        require(videoChanges.none { it } || video.video.text("codec_name") in setOf("h264", "hevc")) { "多数分集编码暂不支持统一转换，原文件已保留" }
        probes.forEachIndexed { index, source -> if (videoChanges[index]) {
            val a = source.video.text("color_transfer"); val b = video.video.text("color_transfer")
            require(!(a in setOf("smpte2084", "arib-std-b67") || b in setOf("smpte2084", "arib-std-b67")) || a == b) { "分集包含不同 HDR 色彩格式，暂不自动转换，避免改变画面色彩" }
        } }
        require(audio == null || audioChanges.none { it } || audio.audio.text("codec_name") in setOf("aac", "ac3", "eac3", "flac", "alac", "mp2", "pcm_s16le", "pcm_s24le")) { "多数音轨格式暂不支持统一编码，可先按分集导出" }
        transport = video.video.text("codec_name") in setOf("h264", "hevc") && (audio == null || audio.audio.text("codec_name") in setOf("aac", "ac3", "eac3", "mp2"))
        require(transport || probes.all { it.video.opt("extradata_hash") == video.video.opt("extradata_hash") }) { "视频编码参数不适合直接拼接，可保留分集并导出 Emby" }
    }
    fun arguments(input: String, output: String, probe: MediaProbe, index: Int): List<String> {
        val args = mutableListOf("-y", "-v", "error", "-i", input)
        val silence = audio != null && probe.audio.length() == 0
        if (silence) {
            val stream = audio!!.audio
            val layout = when (stream.optInt("channels")) { 1 -> "mono"; 2 -> "stereo"; else -> stream.text("channel_layout", "stereo") }
            args.addAll(listOf("-f", "lavfi", "-i", "anullsrc=r=${stream.text("sample_rate")}:cl=$layout"))
        }
        args.addAll(listOf("-map", "0:v:0"))
        if (audio != null) args.addAll(listOf("-map", if (silence) "1:a:0" else "0:a:0"))
        if (videoChanges[index]) {
            val stream = video.video; val width = stream.getInt("width"); val height = stream.getInt("height")
            require(width in 1..16384 && height in 1..16384)
            val hevc = stream.text("codec_name") == "hevc"
            args.addAll(listOf("-c:v", if (hevc) "libx265" else "libx264", "-preset", "veryfast", "-crf", "18", "-threads", "2", "-vf", "scale=$width:$height:force_original_aspect_ratio=decrease,pad=$width:$height:(ow-iw)/2:(oh-ih)/2,setsar=${stream.text("sample_aspect_ratio", "1:1").replace(':', '/')},format=${stream.text("pix_fmt", "yuv420p")}"))
            if (hevc) args.addAll(listOf("-x265-params", "pools=2:frame-threads=1"))
        } else args.addAll(listOf("-c:v", "copy"))
        if (audio != null) {
            if (audioChanges[index]) {
                args.addAll(listOf("-c:a", audio.audio.text("codec_name"), "-ar", audio.audio.text("sample_rate"), "-ac", audio.audio.text("channels")))
                if (audio.audio.text("codec_name") == "aac") args.addAll(listOf("-profile:a", "aac_low"))
                if (audio.audio.text("codec_name") in setOf("aac", "ac3", "eac3", "mp2")) args.addAll(listOf("-b:a", "192k"))
            }
            else args.addAll(listOf("-c:a", "copy"))
        }
        if (silence) args.addAll(listOf("-t", probe.duration.toString()))
        args.addAll(listOf("-map_metadata", "-1", "-avoid_negative_ts", "make_zero"))
        if (transport) args.addAll(listOf("-bsf:v", if (video.video.text("codec_name") == "h264") "h264_mp4toannexb" else "hevc_mp4toannexb", "-mpegts_flags", "+resend_headers", "-f", "mpegts"))
        args.add(output)
        return args
    }
}
