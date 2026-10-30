echo ===== DQ10 RECOVERY: exporting eMMC (mmc 1) as USB mass storage =====
mmc list
mmc dev 1
mmc info
ums 0 mmc 1
