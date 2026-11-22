// npu-run: check and benchmark the Sky1 NPU through Arm China's open libaipudrv (scripts/npu-umd.sh).
//
//   npu-run info                         driver versions, partitions, clusters, cores
//   npu-run bench MODEL [ITERS]          load a compiled graph, run it ITERS times (default 100) on zero input
//   npu-run classify MODEL IMAGE.f32 [LABELS]
//                                        run on one float32 input (as written by tools/npu-prep.py), quantized
//                                        with the graph's scale and zero point; print the top 5 of output 0
//
// MODEL is a CIX model hub .cix file or a bare Zhouyi ELF graph. A .cix file wraps the ELF graph: it starts
// at the "\x7fELF" magic and its length is the 32-bit little-endian word just before it.
//
// Build: g++ -std=c++14 -O2 -I/usr/local/include/aipu -o npu-run tools/npu-run.cpp -laipudrv
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "standard_api.h"

static const aipu_ctx_handle_t *g_ctx;

static void check(aipu_status_t s, const char *what) {
  if (s == AIPU_STATUS_SUCCESS) return;
  const char *msg = "?";
  if (g_ctx) aipu_get_error_message(g_ctx, s, &msg);
  fprintf(stderr, "%s failed: %d (%s)\n", what, (int)s, msg);
  exit(1);
}

static std::vector<char> read_file(const char *path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) { fprintf(stderr, "cannot read %s\n", path); exit(1); }
  return std::vector<char>(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

// Returns the ELF graph inside a .cix file (or the file itself if it is already an ELF).
static std::vector<char> graph_bytes(const char *path) {
  std::vector<char> b = read_file(path);
  static const char magic[4] = {0x7f, 'E', 'L', 'F'};
  if (b.size() >= 4 && !memcmp(b.data(), magic, 4)) return b;
  for (size_t i = 4; i + 4 <= b.size(); i++) {
    if (memcmp(&b[i], magic, 4)) continue;
    uint32_t len;
    memcpy(&len, &b[i - 4], 4);  // little-endian on arm64
    if (len > 4 && i + len <= b.size()) return std::vector<char>(b.begin() + i, b.begin() + i + len);
  }
  fprintf(stderr, "%s: no ELF graph found\n", path);
  exit(1);
}

static void info() {
  uint32_t parts = 0;
  check(aipu_get_partition_count(g_ctx, &parts), "get_partition_count");
  printf("partitions: %u\n", parts);
  for (uint32_t p = 0; p < parts; p++) {
    uint32_t clusters = 0;
    check(aipu_get_cluster_count(g_ctx, p, &clusters), "get_cluster_count");
    for (uint32_t c = 0; c < clusters; c++) {
      uint32_t cores = 0;
      check(aipu_get_core_count(g_ctx, p, c, &cores), "get_core_count");
      printf("partition %u cluster %u: %u cores\n", p, c, cores);
    }
  }
  char target[64] = {0};
  if (aipu_get_target(g_ctx, target) == AIPU_STATUS_SUCCESS) printf("target: %s\n", target);
  aipu_driver_version_t v;
  memset(&v, 0, sizeof(v));
  if (aipu_ioctl(const_cast<aipu_ctx_handle_t *>(g_ctx), AIPU_IOCTL_GET_VERSION, &v) == AIPU_STATUS_SUCCESS)
    printf("umd %s, kmd %s\n", v.umd_version, v.kmd_version);
  device_status_t st;
  if (aipu_get_device_status(g_ctx, &st) == AIPU_STATUS_SUCCESS)
    printf("device status: %s\n", st == DEV_IDLE ? "idle" : st == DEV_BUSY ? "busy" : "exception");
}

static const char *type_name(aipu_data_type_t t) {
  switch (t) {
    case AIPU_DATA_TYPE_U8: return "u8";
    case AIPU_DATA_TYPE_S8: return "s8";
    case AIPU_DATA_TYPE_U16: return "u16";
    case AIPU_DATA_TYPE_S16: return "s16";
    case AIPU_DATA_TYPE_S32: return "s32";
    case AIPU_DATA_TYPE_U32: return "u32";
    case AIPU_DATA_TYPE_F16: return "f16";
    case AIPU_DATA_TYPE_F32: return "f32";
    default: return "other";
  }
}

static std::vector<aipu_tensor_desc_t> tensors(uint64_t job, aipu_tensor_type_t type, const char *name) {
  uint32_t n = 0;
  check(aipu_get_tensor_count(g_ctx, job, type, &n), "get_tensor_count");
  std::vector<aipu_tensor_desc_t> d(n);
  for (uint32_t i = 0; i < n; i++) {
    check(aipu_get_tensor_descriptor(g_ctx, job, type, i, &d[i]), "get_tensor_descriptor");
    printf("%s %u: %u bytes, %s, scale %g, zero point %d\n", name, i, d[i].size, type_name(d[i].data_type),
           d[i].scale, d[i].zero_point);
  }
  return d;
}

// float -> the input tensor's quantized type (q = x * scale + zero_point, as the Compass graphs define it)
static void quantize(const std::vector<float> &x, const aipu_tensor_desc_t &d, std::vector<char> &out) {
  out.assign(d.size, 0);
  size_t n;
  switch (d.data_type) {
    case AIPU_DATA_TYPE_U8: case AIPU_DATA_TYPE_S8: n = d.size; break;
    case AIPU_DATA_TYPE_U16: case AIPU_DATA_TYPE_S16: n = d.size / 2; break;
    case AIPU_DATA_TYPE_F32: n = d.size / 4; break;
    default: fprintf(stderr, "input type %s not handled\n", type_name(d.data_type)); exit(1);
  }
  if (x.size() != n) { fprintf(stderr, "input has %zu values, tensor needs %zu\n", x.size(), n); exit(1); }
  for (size_t i = 0; i < n; i++) {
    if (d.data_type == AIPU_DATA_TYPE_F32) { memcpy(&out[i * 4], &x[i], 4); continue; }
    long v = lrintf(x[i] * d.scale) + d.zero_point;
    switch (d.data_type) {
      case AIPU_DATA_TYPE_U8: out[i] = (char)(uint8_t)std::min(255L, std::max(0L, v)); break;
      case AIPU_DATA_TYPE_S8: out[i] = (char)(int8_t)std::min(127L, std::max(-128L, v)); break;
      case AIPU_DATA_TYPE_U16: { uint16_t q = (uint16_t)std::min(65535L, std::max(0L, v)); memcpy(&out[i * 2], &q, 2); break; }
      default: { int16_t q = (int16_t)std::min(32767L, std::max(-32768L, v)); memcpy(&out[i * 2], &q, 2); break; }
    }
  }
}

static std::vector<float> dequantize(const std::vector<char> &b, const aipu_tensor_desc_t &d) {
  std::vector<float> r;
  float s = d.scale != 0 ? d.scale : 1.0f;
  switch (d.data_type) {
    case AIPU_DATA_TYPE_U8: for (char c : b) r.push_back(((uint8_t)c - d.zero_point) / s); break;
    case AIPU_DATA_TYPE_S8: for (char c : b) r.push_back(((int8_t)c - d.zero_point) / s); break;
    case AIPU_DATA_TYPE_U16: case AIPU_DATA_TYPE_S16:
      for (size_t i = 0; i + 2 <= b.size(); i += 2) {
        int v;
        if (d.data_type == AIPU_DATA_TYPE_U16) { uint16_t q; memcpy(&q, &b[i], 2); v = q; }
        else { int16_t q; memcpy(&q, &b[i], 2); v = q; }
        r.push_back((v - d.zero_point) / s);
      }
      break;
    case AIPU_DATA_TYPE_F32:
      for (size_t i = 0; i + 4 <= b.size(); i += 4) { float f; memcpy(&f, &b[i], 4); r.push_back(f); }
      break;
    default: break;
  }
  return r;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s info | bench MODEL [ITERS] | classify MODEL IMAGE.f32 [LABELS]\n", argv[0]);
    return 2;
  }
  std::string cmd = argv[1];
  aipu_ctx_handle_t *ctx = nullptr;
  check(aipu_init_context(&ctx), "init_context");
  g_ctx = ctx;
  if (cmd == "info") { info(); aipu_deinit_context(ctx); return 0; }
  if ((cmd != "bench" && cmd != "classify") || argc < 3 || (cmd == "classify" && argc < 4)) {
    fprintf(stderr, "bad arguments\n");
    return 2;
  }

  std::vector<char> g = graph_bytes(argv[2]);
  uint64_t graph = 0, job = 0;
  auto t0 = std::chrono::steady_clock::now();
  check(aipu_load_graph_helper(ctx, g.data(), (uint32_t)g.size(), &graph), "load_graph");
  check(aipu_create_job(ctx, graph, &job), "create_job");
  auto t1 = std::chrono::steady_clock::now();
  printf("graph %zu bytes, loaded and job created in %.1f ms\n", g.size(),
         std::chrono::duration<double, std::milli>(t1 - t0).count());
  std::vector<aipu_tensor_desc_t> in = tensors(job, AIPU_TENSOR_TYPE_INPUT, "input");
  std::vector<aipu_tensor_desc_t> out = tensors(job, AIPU_TENSOR_TYPE_OUTPUT, "output");

  std::vector<std::vector<char>> inputs(in.size());
  for (size_t i = 0; i < in.size(); i++) inputs[i].assign(in[i].size, 0);
  if (cmd == "classify") {
    std::vector<char> raw = read_file(argv[3]);
    std::vector<float> x(raw.size() / 4);
    memcpy(x.data(), raw.data(), x.size() * 4);
    quantize(x, in[0], inputs[0]);
  }

  int iters = cmd == "bench" ? (argc > 3 ? atoi(argv[3]) : 100) : 1;
  std::vector<double> ms;
  for (int it = 0; it < iters; it++) {
    auto a = std::chrono::steady_clock::now();
    for (size_t i = 0; i < in.size(); i++) check(aipu_load_tensor(ctx, job, i, inputs[i].data()), "load_tensor");
    check(aipu_finish_job(ctx, job, 10000), "finish_job");
    auto b = std::chrono::steady_clock::now();
    ms.push_back(std::chrono::duration<double, std::milli>(b - a).count());
  }
  std::vector<char> o0(out.empty() ? 0 : out[0].size);
  if (!out.empty()) check(aipu_get_tensor(ctx, job, AIPU_TENSOR_TYPE_OUTPUT, 0, o0.data()), "get_tensor");

  std::sort(ms.begin(), ms.end());
  double sum = 0;
  for (double m : ms) sum += m;
  printf("%d runs: mean %.2f ms, p50 %.2f ms, min %.2f ms, max %.2f ms (%.1f per second)\n", iters,
         sum / iters, ms[ms.size() / 2], ms.front(), ms.back(), 1000.0 * iters / sum);

  if (cmd == "classify" && !out.empty()) {
    std::vector<float> y = dequantize(o0, out[0]);
    std::vector<std::string> labels;
    if (argc > 4) {
      std::ifstream lf(argv[4]);
      for (std::string l; std::getline(lf, l);) labels.push_back(l);
    }
    std::vector<int> idx(y.size());
    for (size_t i = 0; i < idx.size(); i++) idx[i] = (int)i;
    size_t k = std::min<size_t>(5, idx.size());
    std::partial_sort(idx.begin(), idx.begin() + k, idx.end(), [&](int a, int b) { return y[a] > y[b]; });
    for (size_t i = 0; i < k; i++)
      printf("  %5d  %8.3f  %s\n", idx[i], y[idx[i]], idx[i] < (int)labels.size() ? labels[idx[i]].c_str() : "");
  }

  aipu_clean_job(ctx, job);
  aipu_unload_graph(ctx, graph);
  aipu_deinit_context(ctx);
  return 0;
}
