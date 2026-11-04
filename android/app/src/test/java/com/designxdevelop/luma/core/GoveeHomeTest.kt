package com.designxdevelop.luma.core

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Response shapes per goveetl @ 3890402 / homebridge-govee @ c7b3037, as GoveeHomeImport.swift reads them. No real account. */
class GoveeHomeTest {
    @Test fun parsesRoomsGroupsAndAutomations() {
        val list = """{"status":200,"data":{"groups":[{"groupId":7,"groupName":"Den"}],"devices":[
            {"device":"AA:BB","sku":"H6008","deviceName":"Lamp","groupId":7,"deviceExt":{"deviceSettings":"{\"bleName\":\"ihoment_H6008_1A2B\",\"address\":\"A4:C1\"}"}},
            {"device":"CC","sku":"H6199","deviceName":" ","groupId":9},{"sku":"H1"}]}}""".toByteArray()
        val entries = GoveeHomeImport.parse(list)
        assertEquals(listOf("Den", null), entries.map { it.room })
        assertEquals("ihoment_H6008_1A2B", entries[0].bleName); assertEquals("H6199", entries[1].name)
        val plan = GoveeHomeImport.plan(entries, listOf(LightDevice("aa:bb", "h6008", "Lamp")))
        assertEquals(GoveeHomeImport.RoomChange("aa:bb", "Lamp", "Unassigned", "Den"), plan.changes.single())
        assertTrue(plan.changes.single().selectedByDefault); assertEquals(1, plan.notInLuma.size)
        assertThrows(LumaException::class.java) { GoveeHomeImport.parse("""{"status":401}""".toByteArray()) }

        val groups = GoveeHomeImport.parseGroups("""{"status":200,"data":{"list":[{"groupId":1,"name":"Living Room Dream View","enable":1,"deviceCount":3,"type":10,"sceneFeastId":5,"mainDevice":{"device":"TV","sku":"H6199"}},{"groupId":2,"name":"Plain","enable":0,"type":1}]}}""".toByteArray())
        assertTrue(groups[0].isDreamView && groups[0].enabled); assertEquals(3, groups[0].reportedLightCount); assertFalse(groups[1].isDreamView)

        val autos = GoveeHomeImport.parseAutomations("""{"data":{"autoExecs":[{"groupId":4,"name":"Good Morning","enable":1,"schedule":{"times":[{"hour":7,"minute":0},{"hour":25,"minute":0}],"repeat":[1,2,3,4,5,6,7],"skus":[{"sku":"H6008","deviceName":"Lamp"},{"sku":"H6199","isFeast":1,"feastName":"Dream"}]}}]}}""".toByteArray())
        assertEquals(listOf(GoveeHomeImport.Automation.Time(7, 0)), autos[0].times)
        assertEquals(listOf("Lamp", "Dream"), autos[0].targets.map { it.name })
        val lamp = LightDevice("AA:BB", "H6008", "Lamp")
        val scene = LightScene(name = "Wake", steps = listOf(SceneStep(deviceID = "AA:BB", command = CapabilityCommand.power(true))))
        val schedule = SceneSchedule(sceneID = scene.id, hour = 7, minute = 0)
        assertEquals("Good Morning", GoveeHomeImport.conflicts(autos, listOf(schedule), listOf(scene), listOf(lamp)).single().automation)
        assertTrue(GoveeHomeImport.conflicts(autos, listOf(schedule.copy(minute = 1)), listOf(scene), listOf(lamp)).isEmpty())
    }

    @Test fun loginAsksForACodeAndNeverEchoesServerText() = runBlocking {
        val calls = mutableListOf<String>()
        val account = GoveeAccount("client-1", transport = { _, url, headers, body ->
            assertEquals("client-1", headers["clientId"])
            calls += url.substringAfter("govee.com/")
            when {
                url.endsWith("v2/login") && body!!.decodeToString().contains("\"code\"") -> 200 to """{"status":200,"client":{"token":" tok "}}""".toByteArray()
                url.endsWith("v2/login") -> 200 to """{"status":454,"message":"secret@example.com"}""".toByteArray()
                else -> 200 to """{"status":200}""".toByteArray()
            }
        })
        assertEquals(GoveeAccount.LoginResult.NeedsCode, account.login("a@b.c", "pw"))
        assertEquals(listOf("account/rest/account/v2/login", "account/rest/account/v1/verification"), calls)
        assertEquals(GoveeAccount.LoginResult.SignedIn("tok"), account.login("a@b.c", "pw", "123456"))
        val rejected = GoveeAccount("c", transport = { _, _, _, _ -> 200 to """{"status":400,"message":"secret@example.com"}""".toByteArray() })
        val e = assertThrows(LumaException::class.java) { runBlocking { rejected.login("a@b.c", "pw") } }
        assertFalse(e.message!!.contains("secret"))
        val expired = GoveeAccount("c", transport = { _, _, _, _ -> 401 to ByteArray(0) })
        assertThrows(GoveeAccount.SessionExpired::class.java) { runBlocking { expired.groups("t") } }
        Unit
    }
}
