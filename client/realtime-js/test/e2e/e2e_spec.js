import assert from 'assert'
import RealtimeJs from '../../src'

/**
 * Should we allow users to subscribe to both Reatime Streams (CDC)
 * and NOTIFY listeners in the same library?
 */

const Realtime = new RealtimeJs('ws://localhost:4000')
var listenToAll = null
var listenToUsers1 = null
var listenToUsers2 = null

const onUpdate = change => {
  console.log('change', change)
}

describe('Reatime JS', () => {
  it.skip('allow mutilple listeners', async () => {
    listenToAll = Realtime.stream('*', onUpdate, {})
    listenToUsers1 = Realtime.stream('users', onUpdate, {})
    listenToUsers2 = Realtime.stream('users', onUpdate, {})
  })

  it.skip('should receive changes', async () => {
    // trigger a change on the database users table
    // make suer onUpdate is called thrice
  })

  it.skip('should be able to unsubscribe from a listener', async () => {
    const result = Realtime.unsubscribe(listenToUsers1)
    assert(result == true)
  })

  it.skip('should still receive changes for the remaining listeners', async () => {
    // trigger a change on the database users table
    // make suer onUpdate is called twice
  })
  it.skip('should only receive updates for relevant tables', async () => {
    // trigger a change on the database todos table
    // make sure onUpdate is called once from "listenToAll"
  })
})
