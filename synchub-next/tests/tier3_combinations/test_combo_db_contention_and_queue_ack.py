"""
Tier 3 Combination Tests - Suite 5: SQLite Contention + Auto-Pull Delivery ACK + Upload Socket
Pairs Features (S1 x S2 x S3):
Simultaneous uploads from multiple devices, auto-pull queries with delivery ACKs,
and Keep-Alive socket error handling under SQLite WAL concurrency.
"""

import threading
import unittest
from tests.harness.synchub_harness import SyncHubHarness


class TestComboDbContentionAndQueueAck(unittest.TestCase):
    def setUp(self):
        self.harness = SyncHubHarness()

    def tearDown(self):
        self.harness.close()

    def test_combo_db_contention_and_queue_ack(self):
        errors = []
        threads = []

        def client_workflow(dev_id: str):
            try:
                # 1. Upload item
                st_up, res_up = self.harness.upload_file(
                    f"{dev_id}_file.bin",
                    f"payload_{dev_id}".encode("utf-8"),
                    from_device=dev_id,
                    target_device=f"target_{dev_id}"
                )
                if st_up != 200:
                    errors.append(f"{dev_id} upload failed with status {st_up}")

                # 2. Auto-pull
                st_p, res_p = self.harness.get_json(f"/api/hub/auto-pull?device_id=target_{dev_id}&since_id=0")
                if st_p != 200:
                    errors.append(f"{dev_id} pull failed with status {st_p}")

                # 3. Delivery ACK
                items = res_p.get("items", [])
                if items:
                    ack_id = items[0]["id"]
                    st_ack, _ = self.harness.get_json(f"/api/hub/auto-pull?device_id=target_{dev_id}&ack_id={ack_id}")
                    if st_ack != 200:
                        errors.append(f"{dev_id} ack failed with status {st_ack}")
            except Exception as e:
                errors.append(e)

        for i in range(10):
            t = threading.Thread(target=client_workflow, args=(f"dev_c5_{i}",))
            threads.append(t)
            t.start()

        for t in threads:
            t.join(timeout=10.0)

        self.assertEqual(len(errors), 0, f"Encountered errors during concurrent DB + Queue + Socket operations: {errors}")


if __name__ == "__main__":
    unittest.main()
