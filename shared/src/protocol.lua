-- API protokol sozlesmesi: error kodlari, HTTP status eslemesi, yanit zarfi yardimcilari.
local _M = {}

_M.API_PREFIX = "/api/v1"

_M.ERR = {
  VALIDATION_FAILED = "VALIDATION_FAILED",
  BAD_REQUEST = "BAD_REQUEST",
  UNAUTHORIZED = "UNAUTHORIZED",
  TOKEN_EXPIRED = "TOKEN_EXPIRED",
  TOKEN_REVOKED = "TOKEN_REVOKED",
  INVALID_CREDENTIALS = "INVALID_CREDENTIALS",
  ACCOUNT_DISABLED = "ACCOUNT_DISABLED",
  FORBIDDEN = "FORBIDDEN",
  NOT_FOUND = "NOT_FOUND",
  CONNECTION_NOT_FOUND = "CONNECTION_NOT_FOUND",
  DATABASE_NOT_FOUND = "DATABASE_NOT_FOUND",
  OBJECT_NOT_FOUND = "OBJECT_NOT_FOUND",
  USER_NOT_FOUND = "USER_NOT_FOUND",
  ROW_NOT_FOUND = "ROW_NOT_FOUND",
  QUERY_FAILED = "QUERY_FAILED",
  READONLY_VIOLATION = "READONLY_VIOLATION",
  EMAIL_TAKEN = "EMAIL_TAKEN",
  CONFLICT = "CONFLICT",
  LAST_ADMIN = "LAST_ADMIN",
  SELF_ACTION_FORBIDDEN = "SELF_ACTION_FORBIDDEN",
  RESET_TOKEN_INVALID = "RESET_TOKEN_INVALID",
  CONNECTION_FAILED = "CONNECTION_FAILED",
  PASSWORD_REQUIRED = "PASSWORD_REQUIRED",
  SSH_HOST_KEY_UNKNOWN = "SSH_HOST_KEY_UNKNOWN",
  RATE_LIMITED = "RATE_LIMITED",
  PAYLOAD_TOO_LARGE = "PAYLOAD_TOO_LARGE",
  INTERNAL_ERROR = "INTERNAL_ERROR",
  MAIL_FAILED = "MAIL_FAILED",
  DB_UNAVAILABLE = "DB_UNAVAILABLE",
}

_M.HTTP_STATUS = {
  VALIDATION_FAILED = 422, BAD_REQUEST = 400,
  UNAUTHORIZED = 401, TOKEN_EXPIRED = 401, TOKEN_REVOKED = 401, INVALID_CREDENTIALS = 401,
  ACCOUNT_DISABLED = 403, FORBIDDEN = 403,
  NOT_FOUND = 404, CONNECTION_NOT_FOUND = 404, DATABASE_NOT_FOUND = 404, OBJECT_NOT_FOUND = 404, USER_NOT_FOUND = 404, ROW_NOT_FOUND = 404,
  QUERY_FAILED = 422, READONLY_VIOLATION = 422,
  EMAIL_TAKEN = 409, CONFLICT = 409, LAST_ADMIN = 409, SELF_ACTION_FORBIDDEN = 409,
  RESET_TOKEN_INVALID = 400, CONNECTION_FAILED = 502, RATE_LIMITED = 429, PAYLOAD_TOO_LARGE = 413,
  PASSWORD_REQUIRED = 428, SSH_HOST_KEY_UNKNOWN = 428,
  INTERNAL_ERROR = 500, MAIL_FAILED = 502, DB_UNAVAILABLE = 503,
}

_M.CODE_LIST = {
  "VALIDATION_FAILED", "BAD_REQUEST",
  "UNAUTHORIZED", "TOKEN_EXPIRED", "TOKEN_REVOKED", "INVALID_CREDENTIALS",
  "ACCOUNT_DISABLED", "FORBIDDEN",
  "NOT_FOUND", "CONNECTION_NOT_FOUND", "DATABASE_NOT_FOUND", "OBJECT_NOT_FOUND", "USER_NOT_FOUND", "ROW_NOT_FOUND",
  "QUERY_FAILED", "READONLY_VIOLATION",
  "EMAIL_TAKEN", "CONFLICT", "LAST_ADMIN", "SELF_ACTION_FORBIDDEN",
  "RESET_TOKEN_INVALID", "CONNECTION_FAILED", "PASSWORD_REQUIRED", "SSH_HOST_KEY_UNKNOWN", "RATE_LIMITED", "PAYLOAD_TOO_LARGE",
  "INTERNAL_ERROR", "MAIL_FAILED", "DB_UNAVAILABLE",
}

_M.DEFAULT_MESSAGES = {
  VALIDATION_FAILED = "Girdi doğrulanamadi",
  BAD_REQUEST = "Gecersiz istek",
  UNAUTHORIZED = "Kimlik dogrulama gerekli",
  TOKEN_EXPIRED = "Oturum suresi doldu",
  TOKEN_REVOKED = "Token iptal edildi",
  INVALID_CREDENTIALS = "E-posta veya parola hatali",
  ACCOUNT_DISABLED = "Hesabiniz pasif durumda",
  FORBIDDEN = "Bu islem icin yetkiniz yok",
  NOT_FOUND = "Kaynak bulunamadi",
  CONNECTION_NOT_FOUND = "Baglanti bulunamadi",
  DATABASE_NOT_FOUND = "Veritabani bulunamadi",
  OBJECT_NOT_FOUND = "Tablo veya view bulunamadi",
  USER_NOT_FOUND = "Kullanici bulunamadi",
  ROW_NOT_FOUND = "Satir bulunamadi",
  QUERY_FAILED = "Sorgu calistirilamadi",
  READONLY_VIOLATION = "Yalnizca okuma islemine izin var",
  EMAIL_TAKEN = "Bu e-posta zaten kullaniliyor",
  CONFLICT = "Cakisma olustu",
  LAST_ADMIN = "Sistemdeki son aktif admin degistirilemez",
  SELF_ACTION_FORBIDDEN = "Kendi hesabiniz uzerinde bu islem yapilamaz",
  RESET_TOKEN_INVALID = "Gecersiz veya suresi dolmus sifirlama baglantisi",
  CONNECTION_FAILED = "Baglanti kurulamadi",
  PASSWORD_REQUIRED = "Bu baglanti icin parola gerekli",
  SSH_HOST_KEY_UNKNOWN = "SSH sunucu anahtari henuz onaylanmadi",
  RATE_LIMITED = "Cok fazla deneme, lutfen bekleyin",
  PAYLOAD_TOO_LARGE = "Istek govdesi cok buyuk",
  INTERNAL_ERROR = "Beklenmeyen bir hata olustu",
  MAIL_FAILED = "E-posta gonderilemedi",
  DB_UNAVAILABLE = "Veritabanina ulasilamiyor",
}

function _M.http_status(code)
  return _M.HTTP_STATUS[code] or 500
end

function _M.message(code)
  return _M.DEFAULT_MESSAGES[code] or "Beklenmeyen bir hata olustu"
end

function _M.new_error(code, message, details)
  return {
    code = code,
    message = message or _M.message(code),
    details = details,
  }
end

function _M.error_body(err, req_id)
  return {
    error = {
      code = err.code,
      message = err.message or _M.message(err.code),
      details = err.details,
      req_id = req_id,
    },
  }
end

function _M.parse_error(body)
  if type(body) ~= "table" then return nil end
  local e = body.error
  if type(e) ~= "table" then return nil end
  return e
end

function _M.is_refreshable(code)
  return code == _M.ERR.TOKEN_EXPIRED
end

return _M
