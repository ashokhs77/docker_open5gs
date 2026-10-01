# OpenSIPS 4.0 from source -- in-path MMTel/conference B2BUA anchor for the VoLTE
# merge-call feature. 4.0 (not the 3.6 image) because it adds the two features
# VoLTE needs through a B2BUA: b2b_logic custom_contact_header_params (keeps the
# UE Contact feature tags, so the audio<->video button survives) and
# b2b_entities passthru_prack (relays PRACK end-to-end).

FROM ubuntu:jammy

ENV DEBIAN_FRONTEND=noninteractive

# Build + runtime dependencies. gettext-base = envsubst (config preprocessor);
# m4 = macro expansion; the -dev libs cover the modules we load (tm/rr/b2b/uac/
# sipmsgops/signaling + tls/json/pcre for a standard build).
RUN apt-get update && \
	apt-get -y install git gcc g++ make flex bison m4 gettext-base \
		pkg-config libssl-dev libpcre2-dev libpcre3-dev libxml2-dev \
		libcurl4-openssl-dev libjson-c-dev libmnl-dev bash-completion \
		libncurses-dev iptables \
		tcpdump net-tools iproute2 iputils-ping vim ca-certificates && \
	rm -rf /var/lib/apt/lists/*

# Fetch OpenSIPS 4.0 (pinned to the 4.0.0 release tag).
RUN mkdir -p /usr/local/src && cd /usr/local/src && \
	git clone https://github.com/OpenSIPS/opensips.git && \
	cd opensips && git checkout 4.0.0

# --- PATCH 1: carry callee-reply Contact feature tags back to the caller --------
# b2b_logic captures Contact feature params on the REQUEST path only, so the 200 OK
# regenerated toward the caller has a bare Contact and the handset hides the
# audio<->video button. (custom_contact_header_params is request->request only.)
# The emit side already exists in _b2b_send_reply(); only the reply-path capture is
# missing. The grep guard fails the build if upstream moves the anchor line.
RUN cd /usr/local/src/opensips && \
	sed -i '/rpl_data.contact =ct;/a\\trpl_data.contact_hdr_params = b2b_extract_msg_contact_hdrs(msg);\t\\' \
		modules/b2b_logic/logic.c && \
	grep -q 'rpl_data.contact_hdr_params = b2b_extract_msg_contact_hdrs(msg);' \
		modules/b2b_logic/logic.c && \
	echo "[patch] b2b_logic reply-path Contact feature-tag capture applied OK"

# --- PATCH 2: hand REFERs on scripted tuples to the script route ----------------
# Native b2b REFER handling would relay the REFER to FreeSWITCH (making the handset
# ring, the rejected design), and dies at "no replaces peer" when the Replaces
# dialog is a b2b client entity -- the REFER is then never answered and the phone
# drops every call. Skip it when the tuple has a per-session req_route, so our
# conf_req route 202s the REFER and re-anchors via MI b2b_bridge instead.
RUN cd /usr/local/src/opensips && \
	sed -i 's|if(msg->first_line.u.request.method_value==METHOD_REFER &&|int b2bl_skip_native_refer=0;\n\t\tif(msg->first_line.u.request.method_value==METHOD_REFER){B2BL_LOCK_GET(hash_index);tuple=b2bl_search_tuple_safe(hash_index,local_index);if(tuple\&\&tuple->req_route)b2bl_skip_native_refer=1;B2BL_LOCK_RELEASE(hash_index);}\n\t\tif(!b2bl_skip_native_refer\&\&msg->first_line.u.request.method_value==METHOD_REFER \&\&|' \
		modules/b2b_logic/logic.c && \
	grep -q 'b2bl_skip_native_refer' modules/b2b_logic/logic.c && \
	echo "[patch] b2b_logic REFER-to-script-route applied OK"

# --- PATCH 3: honour a per-session request route even under "top hiding" --------
# Under top-hiding, b2b_logic_notify_request auto-forwards every in-dialog request
# and ignores req_route, so conf_req (patch 2) never ran. Drop the top-hiding
# clause so the gate keys purely on req_route: normal anchors still auto-forward,
# only the conf-factory session runs the script route. The REPLY-path gate
# (tuple->reply_route, next occurrence) is deliberately left unchanged.
RUN cd /usr/local/src/opensips && \
	sed -i '/!ref_script_route_check_and_update(tuple->req_route)/{N;s/\n\t|| tuple->scenario_id == B2B_TOP_HIDING_ID_PTR) {/) {/;}' \
		modules/b2b_logic/logic.c && \
	grep -q 'ref_script_route_check_and_update(tuple->req_route)) {' modules/b2b_logic/logic.c && \
	echo "[patch] b2b_logic req-route-under-top-hiding applied OK"

# Build with the module group we need. include_modules pulls in the non-default
# modules (b2b_logic, b2b_entities, uac, dialog, proto_tcp) on top of the standard set.
RUN cd /usr/local/src/opensips && \
	make include_modules="b2b_logic b2b_entities uac dialog proto_tcp" all && \
	make include_modules="b2b_logic b2b_entities uac dialog proto_tcp" install

# opensips binary lands in /usr/local/sbin; modules in /usr/local/lib*/opensips/modules
CMD ["/bin/bash"]
