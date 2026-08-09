package io.xiaoaimusic.handoff;

import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

final class OAuthCallbackParser {
    record Result(String code, String error, boolean terminal) {
        boolean isSuccess() { return code != null && error == null; }
    }

    static Result parse(String requestHeader, String expectedState) {
        if (requestHeader == null || requestHeader.length() > 8_192) {
            return failure("请求过大");
        }
        String[] lines = requestHeader.split("\\r\\n", -1);
        if (lines.length < 2) return failure("HTTP 请求格式无效");
        String[] requestLine = lines[0].split(" ", -1);
        if (requestLine.length != 3
                || !"GET".equals(requestLine[0])
                || !"HTTP/1.1".equals(requestLine[2])) {
            return failure("只接受 HTTP/1.1 GET");
        }
        boolean seenHost = false;
        boolean validHost = false;
        for (int index = 1; index < lines.length; index++) {
            int colon = lines[index].indexOf(':');
            if (colon <= 0) continue;
            String name = lines[index].substring(0, colon).trim().toLowerCase(Locale.ROOT);
            String value = lines[index].substring(colon + 1).trim();
            if ("host".equals(name)) {
                if (seenHost) return failure("重复 Host");
                seenHost = true;
                validHost = "127.0.0.1:43827".equals(value);
            }
        }
        if (!validHost) return failure("Host 无效");

        URI target;
        try {
            target = URI.create(requestLine[1]);
        } catch (Exception failure) {
            return failure("回调地址无效");
        }
        if (target.isAbsolute()
                || target.getRawAuthority() != null
                || !"/callback".equals(target.getRawPath())
                || target.getRawFragment() != null) {
            return failure("回调路径无效");
        }
        Map<String, String> query;
        try {
            query = parseUniqueQuery(target.getRawQuery());
        } catch (Exception failure) {
            return failure("回调参数无效");
        }
        if (!SecurityRules.constantTimeEquals(expectedState, query.get("state"))) {
            return failure("state 校验失败");
        }
        String oauthError = query.get("error");
        if (oauthError != null) {
            return new Result(null, "Spotify 返回：" + safeError(oauthError), true);
        }
        String code = query.get("code");
        if (code == null || code.isEmpty() || code.length() > 4_096 || !isVisibleAscii(code)) {
            return failure("授权码无效");
        }
        return new Result(code, null, true);
    }

    private static Result failure(String message) {
        return new Result(null, message, false);
    }

    private static Map<String, String> parseUniqueQuery(String rawQuery) throws Exception {
        Map<String, String> result = new HashMap<>();
        if (rawQuery == null) return result;
        for (String part : rawQuery.split("&", -1)) {
            int equals = part.indexOf('=');
            String rawName = equals < 0 ? part : part.substring(0, equals);
            String rawValue = equals < 0 ? "" : part.substring(equals + 1);
            String name = URLDecoder.decode(rawName, StandardCharsets.UTF_8.name());
            String value = URLDecoder.decode(rawValue, StandardCharsets.UTF_8.name());
            if (result.put(name, value) != null) throw new IllegalArgumentException("duplicate query");
        }
        return result;
    }

    private static boolean hasControl(String value) {
        for (int index = 0; index < value.length(); index++) {
            if (Character.isISOControl(value.charAt(index))) return true;
        }
        return false;
    }

    private static boolean isVisibleAscii(String value) {
        for (int index = 0; index < value.length(); index++) {
            char current = value.charAt(index);
            if (current < 0x21 || current > 0x7e) return false;
        }
        return true;
    }

    private static String safeError(String value) {
        if (value.length() > 80 || hasControl(value)) return "授权未完成";
        return value;
    }

    private OAuthCallbackParser() {}
}
