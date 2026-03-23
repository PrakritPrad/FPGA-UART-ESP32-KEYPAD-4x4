#include <Wire.h>
#include <LiquidCrystal_I2C.h>

LiquidCrystal_I2C lcd(0x27, 16, 2);

#define RXD2 16   // รับจาก FPGA
#define TXD2 -1   // ไม่ใช้ TX

char pinBuf[5] = "";
int pinLen = 0;

String statusText = "WAIT";
int lockoutSeconds = 0;
unsigned long lastLockoutUpdate = 0;

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

void renderLcd() {
  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("ST:");
  lcd.print(statusText);

  lcd.setCursor(0, 1);
  if (lockoutSeconds > 0) {
    lcd.print("WAIT:");
    if (lockoutSeconds < 10) lcd.print("0");
    lcd.print(lockoutSeconds);
    lcd.print("s");
  } else {
    lcd.print("PIN:");
    lcd.print(pinBuf);
    for (int i = pinLen; i < 4; i++) {
      lcd.print('_');
    }
  }
}

void setup() {
  Serial.begin(115200);
  Serial2.begin(9600, SERIAL_8N1, RXD2, TXD2);

  lcd.init();
  lcd.backlight();
  renderLcd();
}

void loop() {
  // Countdown lockout timer
  if (lockoutSeconds > 0) {
    unsigned long now = millis();
    if (now - lastLockoutUpdate >= 1000) {
      lockoutSeconds--;
      lastLockoutUpdate = now;
      renderLcd();
    }
  }

  while (Serial2.available()) {
    char c = Serial2.read();
    Serial.print(c);

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
    } else if (c == 'O') {
      statusText = "WRONG PASSWD";
      resetPinBuffer();
    } else if (c == 'K') {
      statusText = "LOCK";
      lockoutSeconds = 0;
      resetPinBuffer();
    } else if (c == 'L') {
      statusText = "LOCKOUT";
      lockoutSeconds = 10;
      lastLockoutUpdate = millis();
      resetPinBuffer();
    } else {
      statusText = String("RAW:") + c;
    }

    renderLcd();
  }
}
