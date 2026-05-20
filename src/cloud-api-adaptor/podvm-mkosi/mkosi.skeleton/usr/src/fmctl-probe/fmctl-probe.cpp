// fmctl-probe: minimal client for the NVIDIA Fabric Manager SDK.
//
// Purpose
// -------
// Phase-0 spike for the Service-VM model. Validates that an FM running in
// FABRIC_MODE=1 inside the Service VM:
//   1. accepts FM-SDK calls on its TCP port (default 127.0.0.1:6666),
//   2. enumerates the supported "shared NVSwitch" partition catalogue,
//   3. activates / deactivates a chosen partition.
//
// Build / install
// ---------------
// The CANONICAL build path is image-time, NOT runtime. This source is
// vendored into cloud-api-adaptor at:
//   src/cloud-api-adaptor/podvm-mkosi/mkosi.skeleton/usr/src/fmctl-probe/fmctl-probe.cpp
// and compiled by mkosi.postinst inside the rootfs (chroot ${BUILDROOT})
// against the image's own libnvfm from nvidia-fabricmanager-dev. The
// resulting /usr/local/bin/fmctl-probe ships baked into the podvm qcow2.
// The two copies (this one and the CAA one) MUST stay byte-identical;
// run-podvm-build / 04-build-podvm-locally.sh do not auto-sync them.
// verify-svc-vm.sh enforces presence of /usr/local/bin/fmctl-probe and the
// `resolve` subcommand, so an out-of-date or stripped image fails closed.
//
// Manual (host- or SVM-side rebuild for ad-hoc debugging only):
//     g++ -std=c++17 -O2 fmctl-probe.cpp -lnvfm -o fmctl-probe
//
// Usage
// -----
//     fmctl-probe list                          # dump partition catalogue
//     fmctl-probe activate <id>                 # activate partition <id>
//     fmctl-probe deactivate <id>               # deactivate partition <id>
//     fmctl-probe resolve <bdf,bdf,...>         # match by FM-reported pciBusId
//     fmctl-probe resolve-by-physids <id,id,..> # match by FM-reported physicalId
//
// `resolve` works when FM has GPU BDF info populated (i.e. in single-host
// non-FABRIC_MODE setups where FM and the GPUs share an OS instance and the
// NVIDIA driver is loaded locally). In our qemu-shared-nvswitch SVM topology
// FM runs in FABRIC_MODE=1 with NO GPUs in its OS (the GPUs live in tenant
// VMs), so fmGetSupportedFabricPartitions().gpuInfo[].pciBusId is empty for
// every entry and `resolve` ALWAYS returns "no match". Use
// `resolve-by-physids` instead in that case: pass a comma-separated list of
// physicalId integers (the host computes them from the GPU PCI BDFs sorted
// by bus number, the canonical B200 HGX baseboard mapping) and we match
// against fmGetSupportedFabricPartitions().gpuInfo[].physicalId, which IS
// populated by FM regardless of who owns the GPUs.
//
// Both resolve flavors exit 0 with the id on stdout, 2 on no match,
// 3 on ambiguous.
//
// Override target with FM_ADDR env var, e.g. FM_ADDR=127.0.0.1:6666.

#include <nv_fm_agent.h>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <sstream>
#include <string>
#include <vector>

static const char* fmReturnStr(fmReturn_t r) {
    switch (r) {
        case FM_ST_SUCCESS: return "SUCCESS";
        case FM_ST_BADPARAM: return "BADPARAM";
        case FM_ST_GENERIC_ERROR: return "GENERIC_ERROR";
        case FM_ST_NOT_SUPPORTED: return "NOT_SUPPORTED";
        case FM_ST_UNINITIALIZED: return "UNINITIALIZED";
        case FM_ST_TIMEOUT: return "TIMEOUT";
        case FM_ST_VERSION_MISMATCH: return "VERSION_MISMATCH";
        case FM_ST_IN_USE: return "IN_USE";
        case FM_ST_NOT_CONFIGURED: return "NOT_CONFIGURED";
        case FM_ST_CONNECTION_NOT_VALID: return "CONNECTION_NOT_VALID";
        case FM_ST_NVLINK_ERROR: return "NVLINK_ERROR";
        case FM_ST_RESOURCE_BAD: return "RESOURCE_BAD";
        case FM_ST_RESOURCE_IN_USE: return "RESOURCE_IN_USE";
        case FM_ST_RESOURCE_NOT_IN_USE: return "RESOURCE_NOT_IN_USE";
        case FM_ST_RESOURCE_EXHAUSTED: return "RESOURCE_EXHAUSTED";
        case FM_ST_RESOURCE_NOT_READY: return "RESOURCE_NOT_READY";
        case FM_ST_PARTITION_EXISTS: return "PARTITION_EXISTS";
        case FM_ST_PARTITION_ID_IN_USE: return "PARTITION_ID_IN_USE";
        case FM_ST_PARTITION_ID_NOT_IN_USE: return "PARTITION_ID_NOT_IN_USE";
        case FM_ST_NOT_READY: return "NOT_READY";
        default: return "UNKNOWN";
    }
}

static fmReturn_t connectFm(fmHandle_t* handle) {
    const char* addr = std::getenv("FM_ADDR");
    if (!addr || !*addr) addr = "127.0.0.1:6666";

    fmConnectParams_t params{};
    params.version = fmConnectParams_version;
    std::snprintf(params.addressInfo, sizeof(params.addressInfo), "%s", addr);
    params.timeoutMs = 5000;
    params.addressIsUnixSocket = 0;
    params.addressType = NV_FM_API_ADDR_TYPE_INET;

    fmReturn_t r = fmConnect(&params, handle);
    if (r != FM_ST_SUCCESS) {
        std::fprintf(stderr, "fmConnect(%s) failed: %s (%d)\n", addr, fmReturnStr(r), r);
    } else {
        // To stderr, not stdout: stdout is reserved for machine-readable
        // output of subcommands (e.g. resolve-by-physids prints just the
        // partition id on stdout, so any banner here would be parsed as
        // part of the id by the calling shell `pid=$(fmctl-probe ...)`).
        std::fprintf(stderr, "[fmctl] connected to %s\n", addr);
    }
    return r;
}

static int doList(fmHandle_t h) {
    fmFabricPartitionList_t list{};
    list.version = fmFabricPartitionList_version;
    fmReturn_t r = fmGetSupportedFabricPartitions(h, &list);
    if (r != FM_ST_SUCCESS) {
        std::fprintf(stderr, "fmGetSupportedFabricPartitions failed: %s (%d)\n", fmReturnStr(r), r);
        return 1;
    }

    std::printf("supported partitions: %u (max %u on this platform)\n",
                list.numPartitions, list.maxNumPartitions);
    for (unsigned i = 0; i < list.numPartitions; ++i) {
        const auto& p = list.partitionInfo[i];
        std::printf("  partition id=%u  active=%u  numGpus=%u\n",
                    p.partitionId, p.isActive, p.numGpus);
        for (unsigned g = 0; g < p.numGpus; ++g) {
            const auto& gpu = p.gpuInfo[g];
            std::printf("    gpu physicalId=%u  uuid=%s  pci=%s  nvlinks=%u/%u\n",
                        gpu.physicalId, gpu.uuid, gpu.pciBusId,
                        gpu.numNvLinksAvailable, gpu.maxNumNvLinks);
        }
    }
    return 0;
}

static int doActivate(fmHandle_t h, fmFabricPartitionId_t id) {
    fmReturn_t r = fmActivateFabricPartition(h, id);
    std::printf("fmActivateFabricPartition(%u) -> %s (%d)\n", id, fmReturnStr(r), r);
    return r == FM_ST_SUCCESS ? 0 : 1;
}

static int doDeactivate(fmHandle_t h, fmFabricPartitionId_t id) {
    fmReturn_t r = fmDeactivateFabricPartition(h, id);
    std::printf("fmDeactivateFabricPartition(%u) -> %s (%d)\n", id, fmReturnStr(r), r);
    return r == FM_ST_SUCCESS ? 0 : 1;
}

// Normalize a PCI BDF string to canonical form: "DDDDDDDD:BB:DD.F" (lowercase).
// Accepts the four shapes that show up in practice:
//   "c0:00.0"           -- bus:dev.fn (domain implicit zero); operator typed
//   "0000:c0:00.0"      -- 4-hex-digit domain; some Linux tools
//   "00000000:c0:00.0"  -- 8-hex-digit domain; what NVML/FM-SDK returns
//   "00000000:C0:00.0"  -- same with uppercase bus
// Returns empty string if the input is malformed. Used by doResolve() so that
// operator-typed BDFs (`--gpus c0:00.0,d8:00.0`) compare equal to FM-reported
// BDFs (`fmFabricPartitionGpuInfo_t::pciBusId == "00000000:C0:00.0"`) regardless
// of casing or domain prefix.
static std::string normalizeBdf(const std::string& in) {
    unsigned dom = 0, bus = 0, dev = 0, fn = 0;
    int n = 0;
    if (std::sscanf(in.c_str(), "%x:%x:%x.%x%n", &dom, &bus, &dev, &fn, &n) == 4
        && n == static_cast<int>(in.size())) {
        // domain:bus:dev.fn given (any width domain)
    } else if (std::sscanf(in.c_str(), "%x:%x.%x%n", &bus, &dev, &fn, &n) == 3
               && n == static_cast<int>(in.size())) {
        dom = 0;  // domain omitted; treat as zero per Linux PCI convention
    } else {
        return "";
    }
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%08x:%02x:%02x.%x", dom, bus, dev, fn);
    return buf;
}

// Resolve a comma-separated BDF list to the unique partition id whose GPU
// PCI BDF set is exactly the input set. This implements the runtime side of
// the "operator declares GPUs, FM picks the partition" contract documented
// in docs/PARTITION-MAPPING.md.
//
// Exit codes:
//   0  unique match; partition id printed on stdout
//   1  fmGetSupportedFabricPartitions() failed (unrecoverable)
//   2  no supported partition matches the requested BDF set; or input parse fail
//   3  more than one partition matches (this should never happen on a Blackwell
//      baseboard since each (numGpus, gpu-set) combination is unique, but we
//      fail loud rather than silently activate the first hit)
static int doResolve(fmHandle_t h, const std::string& bdfsCsv) {
    fmFabricPartitionList_t list{};
    list.version = fmFabricPartitionList_version;
    fmReturn_t r = fmGetSupportedFabricPartitions(h, &list);
    if (r != FM_ST_SUCCESS) {
        std::fprintf(stderr,
            "fmGetSupportedFabricPartitions failed: %s (%d)\n",
            fmReturnStr(r), r);
        return 1;
    }

    // Parse + normalize the requested BDF list into a sorted set.
    std::set<std::string> wanted;
    {
        std::stringstream ss(bdfsCsv);
        std::string tok;
        while (std::getline(ss, tok, ',')) {
            tok.erase(std::remove_if(tok.begin(), tok.end(),
                                     [](unsigned char c){ return std::isspace(c); }),
                      tok.end());
            if (tok.empty()) continue;
            std::string normalized = normalizeBdf(tok);
            if (normalized.empty()) {
                std::fprintf(stderr,
                    "resolve: cannot parse BDF '%s' "
                    "(expected DDDD:BB:DD.F or BB:DD.F)\n",
                    tok.c_str());
                return 2;
            }
            wanted.insert(normalized);
        }
    }
    if (wanted.empty()) {
        std::fprintf(stderr, "resolve: empty BDF list\n");
        return 2;
    }

    // Walk every supported partition, comparing its GPU BDF set against `wanted`.
    std::vector<unsigned> matches;
    for (unsigned i = 0; i < list.numPartitions; ++i) {
        const auto& p = list.partitionInfo[i];
        if (p.numGpus != wanted.size()) continue;  // fast reject on size
        std::set<std::string> have;
        for (unsigned g = 0; g < p.numGpus; ++g) {
            std::string normalized = normalizeBdf(p.gpuInfo[g].pciBusId);
            if (normalized.empty()) continue;
            have.insert(normalized);
        }
        if (have == wanted) {
            matches.push_back(p.partitionId);
        }
    }

    if (matches.empty()) {
        std::fprintf(stderr,
            "resolve: no supported partition matches BDF set {");
        bool first = true;
        for (const auto& b : wanted) {
            std::fprintf(stderr, "%s%s", first ? "" : ",", b.c_str());
            first = false;
        }
        std::fprintf(stderr,
            "} -- check `fmctl-probe list` for the supported partition catalogue.\n");
        return 2;
    }
    if (matches.size() > 1) {
        std::fprintf(stderr,
            "resolve: AMBIGUOUS -- %zu partitions match BDF set:",
            matches.size());
        for (unsigned id : matches) std::fprintf(stderr, " %u", id);
        std::fprintf(stderr,
            "\n(this is unexpected on a Blackwell baseboard; report to NVIDIA.)\n");
        return 3;
    }

    // stdout: just the partition id, machine-readable for shell wrappers.
    std::printf("%u\n", matches[0]);
    return 0;
}

// Resolve a comma-separated physicalId list to the unique partition id whose
// GPU physicalId set is exactly the input. Used in FABRIC_MODE=1 / shared
// NVSwitch topologies where FM has no local GPUs and so pciBusId is empty
// in fmGetSupportedFabricPartitions(); physicalId is still populated.
//
// Exit codes mirror doResolve():
//   0  unique match; partition id printed on stdout
//   1  fmGetSupportedFabricPartitions() failed (unrecoverable)
//   2  no supported partition matches the requested physicalId set; or parse fail
//   3  more than one partition matches (should not happen on Blackwell)
static int doResolveByPhysIds(fmHandle_t h, const std::string& idsCsv) {
    fmFabricPartitionList_t list{};
    list.version = fmFabricPartitionList_version;
    fmReturn_t r = fmGetSupportedFabricPartitions(h, &list);
    if (r != FM_ST_SUCCESS) {
        std::fprintf(stderr,
            "fmGetSupportedFabricPartitions failed: %s (%d)\n",
            fmReturnStr(r), r);
        return 1;
    }

    // Parse the requested physicalId list into a sorted set.
    std::set<unsigned> wanted;
    {
        std::stringstream ss(idsCsv);
        std::string tok;
        while (std::getline(ss, tok, ',')) {
            tok.erase(std::remove_if(tok.begin(), tok.end(),
                                     [](unsigned char c){ return std::isspace(c); }),
                      tok.end());
            if (tok.empty()) continue;
            char* end = nullptr;
            unsigned long v = std::strtoul(tok.c_str(), &end, 10);
            if (!end || *end != '\0') {
                std::fprintf(stderr,
                    "resolve-by-physids: cannot parse physicalId '%s' "
                    "(expected integer)\n",
                    tok.c_str());
                return 2;
            }
            wanted.insert(static_cast<unsigned>(v));
        }
    }
    if (wanted.empty()) {
        std::fprintf(stderr, "resolve-by-physids: empty id list\n");
        return 2;
    }

    std::vector<unsigned> matches;
    for (unsigned i = 0; i < list.numPartitions; ++i) {
        const auto& p = list.partitionInfo[i];
        if (p.numGpus != wanted.size()) continue;
        std::set<unsigned> have;
        for (unsigned g = 0; g < p.numGpus; ++g) {
            have.insert(p.gpuInfo[g].physicalId);
        }
        if (have == wanted) {
            matches.push_back(p.partitionId);
        }
    }

    if (matches.empty()) {
        std::fprintf(stderr,
            "resolve-by-physids: no supported partition matches physicalId set {");
        bool first = true;
        for (unsigned id : wanted) {
            std::fprintf(stderr, "%s%u", first ? "" : ",", id);
            first = false;
        }
        std::fprintf(stderr,
            "} -- check `fmctl-probe list` for the supported partition catalogue.\n");
        return 2;
    }
    if (matches.size() > 1) {
        std::fprintf(stderr,
            "resolve-by-physids: AMBIGUOUS -- %zu partitions match physicalId set:",
            matches.size());
        for (unsigned id : matches) std::fprintf(stderr, " %u", id);
        std::fprintf(stderr,
            "\n(this is unexpected on a Blackwell baseboard; report to NVIDIA.)\n");
        return 3;
    }

    std::printf("%u\n", matches[0]);
    return 0;
}

static void usage(const char* argv0) {
    std::fprintf(stderr,
        "Usage: %s <command> [args]\n"
        "Commands:\n"
        "  list                          enumerate supported partitions\n"
        "  activate <id>                 activate partition <id>\n"
        "  deactivate <id>               deactivate partition <id>\n"
        "  resolve <bdf,bdf,...>         match by FM-reported pciBusId\n"
        "                                  (works only when FM has local GPUs)\n"
        "  resolve-by-physids <id,id,..> match by FM-reported physicalId\n"
        "                                  (use in FABRIC_MODE=1 / shared NVSwitch\n"
        "                                  -- pciBusId is empty in that mode)\n"
        "Both resolve flavors: exit 0 + id on stdout, 2 if no match, 3 if ambiguous.\n"
        "Environment:\n"
        "  FM_ADDR                       FM SDK address (default 127.0.0.1:6666)\n",
        argv0);
}

int main(int argc, char** argv) {
    if (argc < 2) { usage(argv[0]); return 2; }
    std::string cmd = argv[1];

    fmReturn_t init = fmLibInit();
    if (init != FM_ST_SUCCESS) {
        std::fprintf(stderr, "fmLibInit failed: %s (%d)\n", fmReturnStr(init), init);
        return 1;
    }

    fmHandle_t h = nullptr;
    if (connectFm(&h) != FM_ST_SUCCESS) { fmLibShutdown(); return 1; }

    int rc = 0;
    if (cmd == "list") {
        rc = doList(h);
    } else if (cmd == "activate" && argc >= 3) {
        rc = doActivate(h, static_cast<fmFabricPartitionId_t>(std::atoi(argv[2])));
    } else if (cmd == "deactivate" && argc >= 3) {
        rc = doDeactivate(h, static_cast<fmFabricPartitionId_t>(std::atoi(argv[2])));
    } else if (cmd == "resolve" && argc >= 3) {
        rc = doResolve(h, std::string(argv[2]));
    } else if (cmd == "resolve-by-physids" && argc >= 3) {
        rc = doResolveByPhysIds(h, std::string(argv[2]));
    } else {
        usage(argv[0]);
        rc = 2;
    }

    fmDisconnect(h);
    fmLibShutdown();
    return rc;
}
