// Provision a RANGE of 5G *load* subscribers in the UDR (mongo open5gs.subscribers),
// for the 5G capacity/stress ramps. Separate from the functional UE (IMSI ...0001).
//
// IMSIs = "00101" + 10-digit MSIN, from LOAD_BASE (default 101) for LOAD_COUNT subs,
// i.e. 001010000000101 .. — never touches the functional ...0001 subscriber.
// Same K/OPc/slice/DNNs as provision_5g_subscriber.js. Idempotent. NumberInt-typed
// (the open5gs DBI layer needs BSON int32 or the UDR rejects with "No SST").
//
// Usage (prepend the two vars, then pipe):
//   printf 'var LOAD_BASE=101;var LOAD_COUNT=512;\n' | cat - provision_5g_range.js \
//     | docker exec -i mongo mongo open5gs --quiet
var LOAD_BASE  = (typeof LOAD_BASE  !== 'undefined') ? LOAD_BASE  : 101;
var LOAD_COUNT = (typeof LOAD_COUNT !== 'undefined') ? LOAD_COUNT : 512;
var made = 0;
for (var i = 0; i < LOAD_COUNT; i++) {
  var n = LOAD_BASE + i;
  var imsi = "00101" + ("0000000000" + n).slice(-10);
  db.subscribers.deleteMany({ imsi: imsi });
  db.subscribers.insertOne({
    imsi: imsi, msisdn: [], imeisv: [], mme_host: [], mme_realm: [], purge_flag: [],
    slice: [{
      sst: NumberInt(1), sd: "000001", default_indicator: true,
      session: [
        { name: "internet", type: NumberInt(3), pcc_rule: [],
          ambr: { uplink: { value: NumberInt(1), unit: NumberInt(3) }, downlink: { value: NumberInt(1), unit: NumberInt(3) } },
          qos: { index: NumberInt(9), arp: { priority_level: NumberInt(8), pre_emption_capability: NumberInt(1), pre_emption_vulnerability: NumberInt(1) } } },
        { name: "ims", type: NumberInt(3), pcc_rule: [],
          ambr: { uplink: { value: NumberInt(1), unit: NumberInt(3) }, downlink: { value: NumberInt(1), unit: NumberInt(3) } },
          qos: { index: NumberInt(5), arp: { priority_level: NumberInt(1), pre_emption_capability: NumberInt(1), pre_emption_vulnerability: NumberInt(1) } } }
      ]
    }],
    security: { k: "465B5CE8B199B49FAA5F0A2EE238A6BC", amf: "8000", op: null, opc: "E8ED289DEBA952E4283B54E88E6183CA" },
    ambr: { uplink: { value: NumberInt(1), unit: NumberInt(4) }, downlink: { value: NumberInt(1), unit: NumberInt(4) } },
    access_restriction_data: NumberInt(32), network_access_mode: NumberInt(0), subscriber_status: NumberInt(0),
    operator_determined_barring: NumberInt(0), subscribed_rau_tau_timer: NumberInt(12), schema_version: NumberInt(1), __v: NumberInt(0)
  });
  made++;
}
print("load_provisioned=" + made + " base=" + LOAD_BASE + " total_subs=" + db.subscribers.count());
