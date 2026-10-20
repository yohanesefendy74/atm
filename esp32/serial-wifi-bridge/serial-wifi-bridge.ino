// Gudang ATM - jembatan indikator timbangan A12E -> WiFi (TCP)
// Papan: ESP32 DevKit. Dua cara sambung (pilih satu lewat MODE_OPTO di bawah):
//
// A) CURRENT LOOP + OPTOCOUPLER (MODE_OPTO = true)  <- dipakai sekarang, terisolasi, hanya menerima data
//    Loop (+) --[R seri]--> anoda LED optocoupler (PC817 / 6N137) ; katoda LED --> Loop (-)
//    Optocoupler sisi output: emitor -> GND ESP32 ; kolektor -> GPIO16 (RX2) dan pull-up 10k ke 3V3
//    Arus loop mengalir = transistor ON = RX tertarik ke LOW (terbalik dari UART biasa), jadi sinyal dibalik di firmware (INVERT).
//    Nilai R seri: R = (V loop - 1,2 V) / 10 mA. Bila indikator menyediakan sumber arus 20 mA sendiri (loop "aktif"), R kecil/tidak perlu;
//    bila loop "pasif" butuh catu luar (mis. 12/24 V), pakai catu itu. PASTIKAN dengan manual A12E: terminal, aktif/pasif, polaritas.
//    Jalur kirim (TX) tidak ada: indikator harus diatur mode kirim terus-menerus (continuous), tidak bisa "minta data".
//
// B) RS232C + MAX3232 (MODE_OPTO = false): TXD indikator -> MAX3232 R1IN, R1OUT -> GPIO16 ; GPIO17 -> T1IN, T1OUT -> RXD indikator ; GND bersama.
//    Jangan sambung RS232 langsung ke pin ESP32 (+-12 V merusak ESP32).
//
// ESP32 membuka server TCP port 4001; Gateway (PC) tersambung ke IP:4001 dan menerima byte apa adanya.
#include <WiFi.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

const char* WIFI_SSID = "GANTI-SSID";
const char* WIFI_PASS = "GANTI-PASSWORD";
const bool MODE_OPTO = true;         // true = current loop via optocoupler (terima saja, sinyal dibalik)
const uint32_t BAUD = 9600;          // samakan dengan setting serial indikator A12E
const uint32_t SERIAL_CFG = SERIAL_8N1;
const uint16_t TCP_PORT = 4001;
const char* BLE_NAME = "ATM-TP-01";   // nama siaran BLE; beri nama berbeda per timbangan (ATM-TP-02, ...)
// Servis Nordic UART: aplikasi Krani (Android/iPhone) membaca berat lewat karakteristik TX (notify)
#define NUS_SERVICE "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define NUS_TX      "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
BLECharacteristic* bleTx = nullptr;
bool bleConnected = false;
class BleCb : public BLEServerCallbacks {
  void onConnect(BLEServer*) { bleConnected = true; }
  void onDisconnect(BLEServer* s) { bleConnected = false; s->getAdvertising()->start(); }
};

// IP tetap disarankan (atur di router: DHCP reservation untuk MAC ESP32 ini)
WiFiServer server(TCP_PORT);
WiFiClient client;

void setup() {
  Serial.begin(115200);
  // opto: tanpa TX (-1) dan sinyal RX dibalik; RS232/MAX3232: TX di GPIO17, tidak dibalik
  Serial2.begin(BAUD, SERIAL_CFG, 16, MODE_OPTO ? -1 : 17, MODE_OPTO);
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  while (WiFi.status() != WL_CONNECTED) { delay(500); Serial.print('.'); }
  Serial.printf("\nIP: %s  port %u\n", WiFi.localIP().toString().c_str(), TCP_PORT);
  server.begin();
  server.setNoDelay(true);

  BLEDevice::init(BLE_NAME);
  BLEServer* bs = BLEDevice::createServer();
  bs->setCallbacks(new BleCb());
  BLEService* svc = bs->createService(NUS_SERVICE);
  bleTx = svc->createCharacteristic(NUS_TX, BLECharacteristic::PROPERTY_NOTIFY);
  bleTx->addDescriptor(new BLE2902());
  svc->start();
  bs->getAdvertising()->addServiceUUID(NUS_SERVICE);
  bs->getAdvertising()->start();
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) WiFi.reconnect();   // BLE tetap jalan walau WiFi putus
  // hanya satu Gateway; koneksi baru menggantikan yang lama
  if (WiFi.status() == WL_CONNECTED && server.hasClient()) {
    WiFiClient baru = server.available();
    if (client) client.stop();
    client = baru;
    client.setNoDelay(true);
  }
  uint8_t buf[128];
  while (Serial2.available()) {                       // indikator -> Gateway
    size_t n = Serial2.readBytes(buf, min((size_t)Serial2.available(), sizeof(buf)));
    if (client && client.connected()) client.write(buf, n);
    if (bleConnected && bleTx) {                          // BLE: paket maks 20 byte (MTU bawaan)
      for (size_t i = 0; i < n; i += 20) { bleTx->setValue(buf + i, min((size_t)20, n - i)); bleTx->notify(); delay(5); }
    }
  }
  while (client && client.connected() && client.available()) {   // Gateway -> indikator
    size_t n = client.readBytes(buf, min((size_t)client.available(), sizeof(buf)));
    if (!MODE_OPTO) Serial2.write(buf, n);   // mode opto: tidak ada jalur kirim
  }
}
