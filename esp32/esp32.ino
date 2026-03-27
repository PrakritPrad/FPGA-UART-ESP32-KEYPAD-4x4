#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <UniversalTelegramBot.h>
#include <ArduinoJson.h>
#include <time.h>
#include <SPIFFS.h>
#include <vector>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/queue.h>

LiquidCrystal_I2C lcd(0x27, 16, 2);

#define RXD2 16   // รับจาก FPGA
#define TXD2 -1   // ไม่ใช้ TX

// Demo credentials for public repository. Replace before real deployment.
const char *ssid = "DEMO_WIFI_SSID";
const char *password = "DEMO_WIFI_PASSWORD";

// Demo Telegram settings for public repository. Replace with your own values.
const char *botToken = "0000000000:DEMO_TELEGRAM_BOT_TOKEN";
const char *MASTER_CODE = "DEMO";  // Master verification code

WiFiClientSecure client;
UniversalTelegramBot bot(botToken, client);

// Multi-user chat IDs
std::vector<String> chatIds;
const int MAX_CHATS = 10;

// Verification state
struct VerifyState {
  String pendingUserId;
  unsigned long pendingTime;
};
VerifyState verifyState = {"", 0};
const unsigned long VERIFY_TIMEOUT = 60000;  // 60 second timeout
const unsigned long BOT_POLL_INTERVAL_MS = 3000;
const unsigned long NETWORK_TASK_INTERVAL_MS = 20;
const bool DEBUG_UART_STREAM = false;

const long GMT_OFFSET_SEC = 7 * 3600; // Thailand UTC+7
const int DAYLIGHT_OFFSET_SEC = 0;

char pinBuf[5] = "";
int pinLen = 0;

String statusText = "WAIT";
int lockoutSeconds = 0;
unsigned long lastLockoutUpdate = 0;
const unsigned long ALERT_SEND_INTERVAL_MS = 1200;

enum AlertEvent : uint8_t {
  ALERT_UNLOCK = 1,
  ALERT_LOCK = 2,
  ALERT_LOCKOUT = 3
};

QueueHandle_t alertQueue = nullptr;

void ensureWiFiConnected() {
  if (WiFi.status() == WL_CONNECTED) return;
  WiFi.begin(ssid, password);
}

void maintainWiFi() {
  // Non-blocking WiFi reconnect check (called periodically from loop)
  static unsigned long lastWiFiCheck = 0;
  if (millis() - lastWiFiCheck >= 5000) {
    lastWiFiCheck = millis();
    if (WiFi.status() != WL_CONNECTED) {
      Serial.println("[WiFi] Attempting reconnect...");
      WiFi.reconnect();
    }
  }
}

String getTimestamp() {
  struct tm timeinfo;
  if (!getLocalTime(&timeinfo)) {
    return String("time-unavailable");
  }
  char buf[32];
  strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &timeinfo);
  return String(buf);
}

// SPIFFS Chat ID Management
void loadChatIds() {
  chatIds.clear();
  
  if (!SPIFFS.exists("/chats.csv")) {
    Serial.println("[SPIFFS] /chats.csv not found, starting fresh");
    return;
  }
  
  File file = SPIFFS.open("/chats.csv", "r");
  if (!file) {
    Serial.println("[SPIFFS] Failed to open /chats.csv");
    return;
  }
  
  while (file.available() && chatIds.size() < MAX_CHATS) {
    String line = file.readStringUntil('\n');
    line.trim();
    if (line.length() > 0) {
      chatIds.push_back(line);
      Serial.print("[SPIFFS] Loaded chat ID: ");
      Serial.println(line);
    }
  }
  file.close();
  Serial.print("[SPIFFS] Total chats loaded: ");
  Serial.println(chatIds.size());
}

void saveChatId(const String &chatId) {
  // Check if already exists
  for (int i = 0; i < chatIds.size(); i++) {
    if (chatIds[i] == chatId) {
      Serial.println("[SPIFFS] Chat ID already registered");
      return;
    }
  }
  
  // Limit to MAX_CHATS
  if (chatIds.size() >= MAX_CHATS) {
    Serial.println("[SPIFFS] Max chats reached");
    return;
  }
  
  // Append to file
  File file = SPIFFS.open("/chats.csv", "a");
  if (!file) {
    Serial.println("[SPIFFS] Failed to open /chats.csv for writing");
    return;
  }
  
  file.println(chatId);
  file.close();
  
  // Add to memory
  chatIds.push_back(chatId);
  Serial.print("[SPIFFS] Saved chat ID: ");
  Serial.println(chatId);
}

bool isChatRegistered(const String &chatId) {
  for (int i = 0; i < chatIds.size(); i++) {
    if (chatIds[i] == chatId) return true;
  }
  return false;
}

void handleBotMessage(const telegramMessage &msg) {
  String userId = msg.chat_id;
  String text = msg.text;
  text.toUpperCase();
  
  // If user already registered, ignore
  if (isChatRegistered(userId)) {
    Serial.println("[Bot] User already registered, ignoring");
    return;
  }
  
  // Check if awaiting verification
  if (verifyState.pendingUserId == userId) {
    // Check timeout
    if (millis() - verifyState.pendingTime > VERIFY_TIMEOUT) {
      verifyState.pendingUserId = "";
      bot.sendMessage(userId, "หมดเวลายืนยัน กรุณา add bot ใหม่อีกครั้ง", "");
      return;
    }
    
    // Check code
    if (text == MASTER_CODE) {
      saveChatId(userId);
      bot.sendMessage(userId, "✅ เพิ่มสำเร็จ! ตอนนี้คุณจะได้รับการแจ้งเตือนเมื่อมีการเปิด/ปิดตู้เซฟ", "");
      verifyState.pendingUserId = "";
      Serial.println("[Bot] Verification SUCCESS");
    } else {
      bot.sendMessage(userId, "❌ รหัสผิด กรุณาลองใหม่", "");
      Serial.println("[Bot] Verification FAILED");
    }
    return;
  }
  
  // New user: prompt for code
  verifyState.pendingUserId = userId;
  verifyState.pendingTime = millis();
  bot.sendMessage(userId, "ยินดีต้อนรับ! กรุณาพิมรหัสยืนยัน เพื่อลงทะเบียน เพื่อลงทะเบียน🔐🛡️", "");
  Serial.println("[Bot] Sent verification prompt to: " + userId);
}

void sendTelegramAlert(const String &message) {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[Alert] WiFi not connected, skipping");
    return;
  }
  
  String payload = message + "\nTime: " + getTimestamp();
  
  // Broadcast to all registered chat IDs
  for (int i = 0; i < chatIds.size(); i++) {
    bool ok = bot.sendMessage(chatIds[i], payload, "");
    Serial.print("[Alert] Send to ");
    Serial.print(chatIds[i]);
    Serial.println(ok ? " OK" : " FAILED");
  }
}

void queueTelegramAlert(AlertEvent event) {
  if (alertQueue == nullptr) return;

  AlertEvent alert = event;

  if (xQueueSend(alertQueue, &alert, 0) != pdTRUE) {
    AlertEvent dropped;
    xQueueReceive(alertQueue, &dropped, 0);
    xQueueSend(alertQueue, &alert, 0);
  }
}

void resetPinBuffer() {
  pinLen = 0;
  pinBuf[0] = '\0';
}

void appendDigit(char d) {
  if (pinLen < 4) {
    pinBuf[pinLen++] = d;
    pinBuf[pinLen] = '\0';
  }
}

void backspaceDigit() {
  if (pinLen > 0) {
    pinLen--;
    pinBuf[pinLen] = '\0';
  }
}

static void padTo16(String &s) {
  while (s.length() < 16) {
    s += ' ';
  }
  if (s.length() > 16) {
    s = s.substring(0, 16);
  }
}

void renderLcd() {
  static String lastLine0 = "";
  static String lastLine1 = "";

  String line0 = "ST:" + statusText;
  padTo16(line0);

  String line1;
  if (lockoutSeconds > 0) {
    line1 = "WAIT:";
    if (lockoutSeconds < 10) line1 += "0";
    line1 += String(lockoutSeconds) + "s";
  } else {
    line1 = "PIN:" + String(pinBuf);
    for (int i = pinLen; i < 4; i++) line1 += "_";
  }
  padTo16(line1);

  if (line0 != lastLine0) {
    lcd.setCursor(0, 0);
    lcd.print(line0);
    lastLine0 = line0;
  }

  if (line1 != lastLine1) {
    lcd.setCursor(0, 1);
    lcd.print(line1);
    lastLine1 = line1;
  }
}

void handleUartChar(char c) {
  if (c >= '0' && c <= '9') {
    appendDigit(c);
    statusText = "ENTER";
  } else if (c == 'G') {
    statusText = "CHG-OLD";
    resetPinBuffer();
  } else if (c == 'N') {
    statusText = "CHG-NEW";
    resetPinBuffer();
  } else if (c == 'A') {
    statusText = "BKSP";
    backspaceDigit();
  } else if (c == 'C') {
    statusText = "CLEAR";
    resetPinBuffer();
  } else if (c == 'U') {
    statusText = "UNLOCK";
    lockoutSeconds = 0;
    resetPinBuffer();
    queueTelegramAlert(ALERT_UNLOCK);
  } else if (c == 'O') {
    statusText = "WRONG PASSWD";
    resetPinBuffer();
  } else if (c == 'K') {
    statusText = "LOCK";
    lockoutSeconds = 0;
    resetPinBuffer();
    queueTelegramAlert(ALERT_LOCK);
  } else if (c == 'L') {
    statusText = "LOCKOUT";
    lockoutSeconds = 10;
    lastLockoutUpdate = millis();
    resetPinBuffer();
    queueTelegramAlert(ALERT_LOCKOUT);
  } else {
    statusText = String("RAW:") + c;
  }
}

void uartTask(void *parameter) {
  (void)parameter;

  for (;;) {
    bool lcdDirty = false;

    while (Serial2.available()) {
      char c = Serial2.read();
      if (DEBUG_UART_STREAM) {
        Serial.print(c);
      }
      handleUartChar(c);
      lcdDirty = true;
    }

    if (lockoutSeconds > 0) {
      unsigned long now = millis();
      if (now - lastLockoutUpdate >= 1000) {
        lockoutSeconds--;
        lastLockoutUpdate = now;
        lcdDirty = true;
      }
    }

    if (lcdDirty) {
      renderLcd();
    }

    vTaskDelay(1);
  }
}

void networkTask(void *parameter) {
  (void)parameter;

  unsigned long lastBotCheck = 0;
  unsigned long lastAlertSendAttempt = 0;
  bool hasPendingAlert = false;
  AlertEvent pendingAlert = ALERT_UNLOCK;

  for (;;) {
    maintainWiFi();

    if (!hasPendingAlert && alertQueue != nullptr) {
      if (xQueueReceive(alertQueue, &pendingAlert, 0) == pdTRUE) {
        hasPendingAlert = true;
      }
    }

    if (hasPendingAlert &&
        (millis() - lastAlertSendAttempt >= ALERT_SEND_INTERVAL_MS) &&
        WiFi.status() == WL_CONNECTED) {
      if (pendingAlert == ALERT_UNLOCK) {
        sendTelegramAlert("ตู้เซฟถูกเปิด");
      } else if (pendingAlert == ALERT_LOCK) {
        sendTelegramAlert("ตู้เซฟถูกปิดแล้ว");
      } else if (pendingAlert == ALERT_LOCKOUT) {
        sendTelegramAlert("แจ้งเตือน !! มีการกรอกรหัสผิดซ้ำหลายครั้ง\nระบบได้ทำการล็อกเป็นเวลา 10 วินาที");
      }
      hasPendingAlert = false;
      lastAlertSendAttempt = millis();
    }

    if (millis() - lastBotCheck >= BOT_POLL_INTERVAL_MS) {
      lastBotCheck = millis();
      if (WiFi.status() == WL_CONNECTED) {
        int numNewMessages = bot.getUpdates(bot.last_message_received + 1);
        if (numNewMessages > 0) {
          Serial.print("[Bot] Got messages: ");
          Serial.println(numNewMessages);
          for (int i = 0; i < numNewMessages; i++) {
            telegramMessage msg = bot.messages[i];
            handleBotMessage(msg);
          }
        }
      }
    }

    vTaskDelay(pdMS_TO_TICKS(NETWORK_TASK_INTERVAL_MS));
  }
}

void setup() {
  Serial.begin(115200);
  Serial.println("\n[Setup] Starting...");
  
  Serial2.begin(9600, SERIAL_8N1, RXD2, TXD2);

  // Initialize SPIFFS
  if (!SPIFFS.begin(true)) {
    Serial.println("[SPIFFS] FAILED to mount");
  } else {
    Serial.println("[SPIFFS] Mounted successfully");
  }
  
  // Load registered chat IDs
  loadChatIds();

  WiFi.mode(WIFI_STA);
  ensureWiFiConnected();
  client.setInsecure();
  configTime(GMT_OFFSET_SEC, DAYLIGHT_OFFSET_SEC, "pool.ntp.org", "time.nist.gov");

  lcd.init();
  lcd.backlight();
  renderLcd();

  alertQueue = xQueueCreate(10, sizeof(AlertEvent));
  if (alertQueue == nullptr) {
    Serial.println("[Queue] Failed to create alert queue");
  }

  BaseType_t uartTaskOk = xTaskCreatePinnedToCore(uartTask, "uartTask", 6144, nullptr, 3, nullptr, 1);
  BaseType_t netTaskOk = xTaskCreatePinnedToCore(networkTask, "networkTask", 12288, nullptr, 1, nullptr, 0);
  if (uartTaskOk != pdPASS || netTaskOk != pdPASS) {
    Serial.println("[Task] Failed to create one or more tasks");
  }
  
  Serial.println("[Setup] Ready!");
}

void loop() {
  vTaskDelay(pdMS_TO_TICKS(1000));
}
