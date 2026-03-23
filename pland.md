## Plan: Basic PIN Lock Flow (Clean)

ปรับระบบให้เรียบง่ายตามข้อกำหนดใหม่: ใช้ `F` เป็นปุ่มยืนยันเท่านั้น, ถ้ากด `F` ตอนกรอกรหัสยังไม่ครบ 4 หลักให้นับเป็นผิดทันที, `G` ใช้เข้าสู่การเปลี่ยนรหัสแต่ต้องยืนยันรหัสเดิมให้ถูกก่อน, และเพิ่มสถานะ UART ใหม่ `U/K/L` พร้อม buzzer. ตัด edge case ลึกๆ ออกเพื่อให้ง่ายต่อ implement และ debug.

**Steps**
1. สร้าง FSM แบบพื้นฐานใน `pin_lock_fsm.vhd` ด้วยสถานะหลัก 4 ตัว: `LOCKED`, `UNLOCKED`, `VERIFY_OLD_FOR_CHANGE`, `LOCKOUT`.
2. นิยามกติกา key ชัดเจน:
   - `0-9` ใช้กรอก digit
   - `F` ใช้ยืนยันเท่านั้น
   - `G` ใช้ร้องขอเปลี่ยนรหัส (เฉพาะตอน `UNLOCKED`)
3. ใน `LOCKED`: เก็บ digit สูงสุด 4 ตัว; เมื่อกด `F`
   - ถ้า digit ยังไม่ครบ 4 => fail ทันที
   - ถ้าครบ 4 และถูก => `UNLOCKED`, UART ส่ง `U`
   - ถ้าครบ 4 และผิด => fail
4. ทำ lockout แบบเรียบง่าย: fail ครบ 5 ครั้งติด เข้า `LOCKOUT` 10 วินาที (test mode ตามที่ขอ) และส่ง UART `L` ตอนเข้าโหมด.
5. ใน `UNLOCKED`: รีเลย์เปิดค้าง; ถ้ากด `F` ให้ล็อกกลับทันที (`LOCKED`) และส่ง UART `K`.
6. ใน `UNLOCKED`: ถ้ากด `G` ให้เข้า `VERIFY_OLD_FOR_CHANGE` เพื่อกรอกรหัสเดิมและกด `F` ยืนยัน:
   - ถ้ารหัสเดิมถูก => เริ่มกรอกรหัสใหม่ 4 หลัก แล้วกด `F` เพื่อ commit
   - ถ้าผิดหรือกด `F` ก่อนครบ 4 => นับ fail (ไม่ต้องทำ edge case เพิ่ม)
7. เก็บรหัสใน register 4 หลัก runtime (ค่าเริ่มต้น hardcoded) เพื่อให้เปลี่ยนรหัสได้ในรอบเปิดเครื่องเดียวกัน.
8. เพิ่ม buzzer output ใน top-level และกำหนดรูปแบบง่ายๆ:
   - beep สั้นเมื่อ keypress
   - beep ยาวเมื่อ `LOCKOUT`
   - beep คู่เมื่อ unlock สำเร็จ
9. ปรับ `top.vhd` ให้ route จาก scanner -> pin_lock_fsm -> uart_tx_core และเพิ่มพอร์ต `Relay` + `Buzzer`.
10. อัปเดต `mapport.ucf` เพิ่มพิน buzzer/relay และอัปเดต `main/UART_TX.prj` ให้รวม `pin_lock_fsm.vhd`.

**Relevant files**
- d:/Digital_vm/test/pin_lock_fsm.vhd — FSM ใหม่ของ lock flow และ PIN register.
- d:/Digital_vm/test/top.vhd — wiring FSM, UART, Relay, Buzzer.
- d:/Digital_vm/test/keypad_scanner.vhd — แหล่ง `key_valid/key_code`.
- d:/Digital_vm/test/uart_tx_core.vhd — ใช้ส่ง event bytes `U/K/L`.
- d:/Digital_vm/test/mapport.ucf — constraint ขารีเลย์และ buzzer.
- d:/Digital_vm/test/main/UART_TX.prj — เพิ่มไฟล์ compile ของ FSM.

**Verification**
1. ใส่รหัสถูก 4 หลักแล้วกด `F` => UART `U`, รีเลย์ ON.
2. กด `F` ตอน `UNLOCKED` => UART `K`, รีเลย์ OFF.
3. ใน `LOCKED` กด `F` ทั้งที่ไม่ครบ 4 หลัก => fail count เพิ่ม.
4. fail ครบ 5 ครั้ง => UART `L`, ไม่รับ input 10 วินาที.
5. ใน `UNLOCKED` กด `G` -> ยืนยันรหัสเดิมถูก -> ตั้งรหัสใหม่สำเร็จ แล้วทดสอบรหัสใหม่ใช้งานได้.
6. Buzzer ทำงานตาม event พื้นฐาน (สั้น/ยาว/คู่) โดยไม่ต้องเน้น pattern ซับซ้อน.

**Decisions**
- โหมดพื้นฐาน เน้น clean flow, ลด edge-case logic.
- `F` = confirm only; กด confirm ก่อนครบ 4 หลักถือว่าผิด.
- `G` = ขอเปลี่ยนรหัส แต่ต้องยืนยันรหัสเดิมก่อน.
- UART events: `U` unlock, `K` re-lock, `L` lockout.
- Lockout test duration: 10 วินาที (ปรับกลับ 30 วินาทีภายหลังได้ด้วย constant เดียว).

**Further Considerations**
1. หลังจบ test ให้เปลี่ยน lockout จาก 10 เป็น 30 วินาทีด้วยคอนสแตนต์เดียว.
2. หากต้องการลด false fail จากการกดพลาด อาจเพิ่มปุ่ม clear ในอนาคต (ไม่รวมในรอบ basic นี้).