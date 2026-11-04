/* Separate fisheye source K and balance=0 output K; no Brown coefficient reuse. */
static float fisheye_intr[9]={2660.38421811f,2671.63308125f,666.975649456f,380.415712623f,0.0f,0.0f,0.0f,0.0f,0.0f};
static const float fisheye_output[4]={2605.18267369f,2616.19812896f,643.345193847f,374.899578856f};
static const float fisheye_dist[4]={-0.0677672021539f,0.0327856178497f,0.0f,0.0f};
#define FISHEYE_CONFIG_TAG 0x46495348u
