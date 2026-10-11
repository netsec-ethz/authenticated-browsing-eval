#include <rte_config.h>
#include <rte_ethdev.h> 
#include <ethdev_driver.h>
#include <rte_mempool.h>
#include <rte_ether.h>
#include <rte_cycles.h>
#include <rte_mbuf.h>
#include <ixgbe_type.h>
#include <rte_mbuf.h>
#include <rte_eth_ctrl.h>
#include <rte_pci.h>
#include <rte_bus_pci.h>
#include <bus_pci_driver.h>

#include "rdtsc.h"

#include "device.h"
#include "timestamping.h"
#include "lifecycle.h"

// default descriptors per queue
#define DEFAULT_RX_DESCS 512
#define DEFAULT_TX_DESCS 256
#define SYMM_RSS_HASHKEY_LENGTH 40

//Source: http://www.ndsl.kaist.edu/~kyoungsoo/papers/TR-symRSS.pdf
static uint8_t symm_rss_hash_key[SYMM_RSS_HASHKEY_LENGTH] = { 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, };

static volatile uint8_t* registers[RTE_MAX_ETHPORTS];

uint32_t read_reg32(uint16_t port, uint32_t reg) {
	return *(volatile uint32_t*)(registers[port] + reg);
}

void write_reg32(uint16_t port, uint32_t reg, uint32_t val) {
	*(volatile uint32_t*)(registers[port] + reg) = val;
}

uint64_t read_reg64(uint16_t port, uint32_t reg) {
	return *(volatile uint64_t*)(registers[port] + reg);
}

void write_reg64(uint16_t port, uint32_t reg, uint64_t val) {
	*(volatile uint64_t*)(registers[port] + reg) = val;
}

volatile uint32_t* get_reg_addr(uint16_t port, uint32_t reg) {
	return (volatile uint32_t*)(registers[port] + reg);
}

int dpdk_get_max_ports() {
	return RTE_MAX_ETHPORTS;
}

struct libmoon_device_config {
	uint32_t port;
	struct rte_mempool** mempools;
	uint16_t rx_queues;
	uint16_t tx_queues;
	uint16_t rx_descs;
	uint16_t tx_descs;
	uint8_t drop_enable;
	uint8_t enable_rss;
	uint8_t disable_offloads;
	uint8_t strip_vlan;
	uint32_t rss_mask;
	uint8_t enable_rss_symm;
};

int dpdk_configure_device(struct libmoon_device_config* cfg) {
	const char* driver = dpdk_get_driver_name(cfg->port);
	bool is_iavf_device = strcmp("net_iavf", driver) == 0;
	bool is_ixgbe_device = strcmp("net_ixgbe", driver) == 0;
	bool is_i40e_device = strcmp("net_i40e", driver) == 0;
	bool is_igb_device = strcmp("net_e1000_igb", driver) == 0;
	bool is_mlx5_device = strcmp("mlx5_pci", driver) == 0;
	struct rte_eth_dev_info dev_info;
	rte_eth_dev_info_get(cfg->port, &dev_info);

	struct rte_eth_rss_conf rss_conf = {
		.rss_key = cfg->enable_rss_symm ? symm_rss_hash_key : NULL,
		.rss_key_len = cfg->enable_rss_symm ? SYMM_RSS_HASHKEY_LENGTH : 0,
		.rss_hf = cfg->rss_mask & dev_info.flow_type_rss_offloads,
	};

	// disable RTE_ETH_RX_OFFLOAD_VLAN_EXTEND on ixgbe and i40e devices. 
	// ixgbe: When this RX offload option is enabled, packet which have TX IP Checksum offloading enabled are not transmitted
	// i40e: When this offload is enabled unused ports on the same card will stop working (and require a reboot to work again)
	uint64_t rx_offloads = (cfg->disable_offloads ?
		(is_mlx5_device ? RTE_ETH_RX_OFFLOAD_SCATTER : 0)
		: (RTE_ETH_RX_OFFLOAD_CHECKSUM | (cfg->strip_vlan ? RTE_ETH_RX_OFFLOAD_VLAN_STRIP : 0) | (!(is_ixgbe_device || is_i40e_device || is_igb_device) ? RTE_ETH_RX_OFFLOAD_VLAN_EXTEND : 0) | RTE_ETH_RX_OFFLOAD_TIMESTAMP | (is_mlx5_device ? RTE_ETH_RX_OFFLOAD_SCATTER: 0)))
		& dev_info.rx_offload_capa;
	uint64_t tx_offloads = (cfg->disable_offloads ?
		RTE_ETH_TX_OFFLOAD_MBUF_FAST_FREE
		: (RTE_ETH_TX_OFFLOAD_VLAN_INSERT | RTE_ETH_TX_OFFLOAD_IPV4_CKSUM | RTE_ETH_TX_OFFLOAD_UDP_CKSUM | RTE_ETH_TX_OFFLOAD_TCP_CKSUM | RTE_ETH_TX_OFFLOAD_MBUF_FAST_FREE))
		& dev_info.tx_offload_capa;
	struct rte_eth_conf port_conf = {
		.rxmode = {
			.mq_mode = cfg->enable_rss ? RTE_ETH_MQ_RX_RSS : RTE_ETH_MQ_RX_NONE,
			.offloads = rx_offloads,

			//subtract 4 byte for possibly transparently inserted vlan tag, when using VFs
			.mtu = dev_info.max_mtu - (is_iavf_device?4:0),
		},
		.txmode = {
			.mq_mode = RTE_ETH_MQ_TX_NONE,
			.offloads = tx_offloads
		},
		.link_speeds = RTE_ETH_LINK_SPEED_AUTONEG,
	  	.rx_adv_conf = {
			.rss_conf = rss_conf,
		} 
	};
	// dev_info reports a invalid result for mlx5 devices -> use a fixed MTU of 9000B
	if(is_mlx5_device) port_conf.rxmode.mtu = 9000;
	// net_tap reports max_mtu 65535 but the kernel only accepts ~1522, so configure fails.
	// e2e-tcp uses a TAP for the wrkout interface, clamp to 1500.
	if(strstr(dev_info.driver_name, "net_tap") != NULL) port_conf.rxmode.mtu = 1500;

	if(!cfg->enable_rss){
		memset(&port_conf.rx_adv_conf, 0, sizeof(port_conf.rx_adv_conf));
	}

	int rc = rte_eth_dev_configure(cfg->port, cfg->rx_queues, cfg->tx_queues, &port_conf);
	if (rc) return rc;

	struct rte_eth_txconf tx_conf = dev_info.default_txconf;
	tx_conf.offloads = tx_offloads;
	for (int i = 0; i < cfg->tx_queues; i++) {
		rc = rte_eth_tx_queue_setup(cfg->port, i, cfg->tx_descs ? cfg->tx_descs : DEFAULT_TX_DESCS, dpdk_get_socket(cfg->port), &tx_conf);
		if (rc) {
			printf("could not configure tx queue %d\n", i);
			return rc;
		}
	}

	struct rte_eth_rxconf rx_conf = dev_info.default_rxconf;
	rx_conf.rx_drop_en = cfg->drop_enable;
	rx_conf.offloads = rx_offloads;
	for (int i = 0; i < cfg->rx_queues; i++) {
		rc = rte_eth_rx_queue_setup(cfg->port, i, cfg->rx_descs ? cfg->rx_descs : DEFAULT_RX_DESCS, dpdk_get_socket(cfg->port), &rx_conf, cfg->mempools[i]);
		if (rc != 0) {
			printf("could not configure rx queue %d\n", i);
			return rc;
		}
	}
	rc = rte_eth_dev_start(cfg->port);
	if (RTE_DEV_TO_PCI(dev_info.device)) {
		registers[cfg->port] = (uint8_t*) RTE_DEV_TO_PCI(dev_info.device)->mem_resource[0].addr;
	} else {
		registers[cfg->port] = NULL;
	}
	return rc;
}

void* dpdk_get_eth_dev(int port) {
	return &rte_eth_devices[port];
}

int dpdk_get_pci_function(int port) {
	struct rte_eth_dev_info dev_info;
	rte_eth_dev_info_get(port, &dev_info);
	if (RTE_DEV_TO_PCI(dev_info.device)) {
		return RTE_DEV_TO_PCI(dev_info.device)->addr.function;
	} else {
		return 0;
	}
}

const char* dpdk_get_driver_name(int port) {
	struct rte_eth_dev_info dev_info;
	rte_eth_dev_info_get(port, &dev_info);
	return dev_info.driver_name;
}

uint64_t dpdk_get_mac_addr(int port, char* buf) {
	struct rte_ether_addr addr;
	rte_eth_macaddr_get(port, &addr);
	if (buf) {
		sprintf(buf, "%02X:%02X:%02X:%02X:%02X:%02X", addr.addr_bytes[0], addr.addr_bytes[1], addr.addr_bytes[2], addr.addr_bytes[3], addr.addr_bytes[4], addr.addr_bytes[5]);
	}
	return addr.addr_bytes[0] | (addr.addr_bytes[1] << 8) | (addr.addr_bytes[2] << 16) | ((uint64_t) addr.addr_bytes[3] << 24) | ((uint64_t) addr.addr_bytes[4] << 32) | ((uint64_t) addr.addr_bytes[5] << 40);
}

uint32_t dpdk_get_pci_id(uint16_t port) {
	struct rte_eth_dev_info dev_info;
	rte_eth_dev_info_get(port, &dev_info);
	if (!RTE_DEV_TO_PCI(dev_info.device)) {
		return 0;
	}
	return RTE_DEV_TO_PCI(dev_info.device)->id.vendor_id << 16 | RTE_DEV_TO_PCI(dev_info.device)->id.device_id;
}

uint8_t dpdk_get_socket(uint16_t port) {
	struct rte_eth_dev_info dev_info;
	rte_eth_dev_info_get(port, &dev_info);
	if (!RTE_DEV_TO_PCI(dev_info.device)) {
		return 0;
	}
	int node = RTE_DEV_TO_PCI(dev_info.device)->device.numa_node;
	if (node == -1) {
		node = 0;
	}
	return (uint8_t) node;
}

uint32_t dpdk_get_rte_queue_stat_cntrs_num() {
	return RTE_ETHDEV_QUEUE_STAT_CNTRS;
}

// the following functions are static inline function in header files
// this is the easiest/least ugly way to make them available to luajit (#defining static before including the header breaks stuff)
uint16_t rte_eth_rx_burst_export(uint16_t port_id, uint16_t queue_id, void* rx_pkts, uint16_t nb_pkts) {
	return rte_eth_rx_burst(port_id, queue_id, rx_pkts, nb_pkts);
}

uint16_t rte_eth_tx_burst_export(uint16_t port_id, uint16_t queue_id, void* tx_pkts, uint16_t nb_pkts) {
	return rte_eth_tx_burst(port_id, queue_id, tx_pkts, nb_pkts);
}

uint16_t rte_eth_tx_prepare_export(uint16_t port_id, uint16_t queue_id, void* tx_pkts, uint16_t nb_pkts) {
	return rte_eth_tx_prepare(port_id, queue_id, tx_pkts, nb_pkts);
}

void dpdk_send_all_packets(uint16_t port_id, uint16_t queue_id, struct rte_mbuf** pkts, uint16_t num_pkts) {
	uint32_t sent = 0;
	while (1) {
		sent += rte_eth_tx_burst(port_id, queue_id, pkts + sent, num_pkts - sent);
		if (sent >= num_pkts) {
			return;
		}
	}
	return;
}

void dpdk_send_single_packet(uint16_t port_id, uint16_t queue_id, struct rte_mbuf* pkt) {
	uint32_t sent = 0;
	while (1) {
		sent = rte_eth_tx_burst(port_id, queue_id, &pkt, 1);
		if (sent > 0) {
			return;
		}
	}
	return;
}


uint16_t dpdk_try_send_single_packet(uint16_t port_id, uint16_t queue_id, struct rte_mbuf* pkt) {
	uint16_t sent = 0;
	sent = rte_eth_tx_burst(port_id, queue_id, &pkt, 1);
	return sent;
}

// receive packets and save the tsc at the time of the rx call
// this prevents potential gc/jit pauses right between the rdtsc and rx calls
uint16_t dpdk_receive_with_timestamps_software(uint16_t port_id, uint16_t queue_id, struct rte_mbuf* rx_pkts[], uint16_t nb_pkts) {
	uint32_t cycles_per_byte = rte_get_tsc_hz() / 10000000.0 / 0.8;
	while (is_running(0)) {
		uint64_t tsc = read_rdtsc();
		uint16_t rx = rte_eth_rx_burst(port_id, queue_id, rx_pkts, nb_pkts);
		uint16_t prev_pkt_size = 0;
		for (int i = 0; i < rx; i++) {
			set_timestamp_dynfield(rx_pkts[i], tsc + prev_pkt_size * cycles_per_byte);
			prev_pkt_size = rx_pkts[i]->pkt_len + 24;
		}
		if (rx > 0) {
			return rx;
		}
	}
	return 0;
}


void rte_pktmbuf_free_export(void* m) {
	rte_pktmbuf_free(m);
}


void rte_delay_ms_export(uint32_t ms) {
	rte_delay_ms(ms);
}

void rte_delay_us_export(uint32_t us) {
	rte_delay_us(us);
}

