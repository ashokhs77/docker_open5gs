// Provision the 5G subscriber that the UERANSIM UE (ue.yaml) authenticates as.
// Idempotent. Run inside the mongo container:
//   docker exec -i mongo mongo open5gs --quiet < provision_5g_subscriber.js
//
// CRITICAL: every integer is wrapped in NumberInt(). The open5gs DBI layer reads
// these fields as BSON int32; the legacy mongo shell otherwise stores JS numbers
// as double, which makes the UDR fail with "No SST"/"No UE-AMBR" -> AMF rejects
// registration with 5GMM cause #7 (5GS services not allowed).
//
// S-NSSAI sst:1 sd:000001 matches amf.yaml plmn_support (its first/preferred
// s_nssai). DNNs internet + ims match smf.yaml.
db.subscribers.deleteMany({ imsi: "001010000000001" });
db.subscribers.insertOne({
  imsi: "001010000000001",
  msisdn: ["0010100000001"], imeisv: [], mme_host: [], mme_realm: [], purge_flag: [],
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
print("subscribers=" + db.subscribers.count());
