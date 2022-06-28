const { RealtimeClient } = require('@supabase/realtime-js')

const REALTIME_URL = process.env.REALTIME_URL || 'http://localhost:4000/socket'
const socket = new RealtimeClient(REALTIME_URL)

// Connect to the realtime server
socket.connect()

// Set up database listener
const DatabaseListener = socket.channel('realtime:*')

DatabaseListener.on('*', (change) => {
  console.log('Change received on DatabaseListener', change)
})

DatabaseListener.subscribe()
  .receive('ok', () => console.log('DatabaseListener connected '))
  .receive('error', () => console.log('Failed'))
  .receive('timeout', () => console.log('Waiting...'))

// Set up schema listener (public schema)
const SchemaListener = socket.channel('realtime:public')

SchemaListener.on('*', (change) => {
  console.log('Change received on SchemaListener', change)
})

SchemaListener.subscribe()
  .receive('ok', () => console.log('SchemaListener connected '))
  .receive('error', () => console.log('Failed'))
  .receive('timeout', () => console.log('Waiting...'))

// Set up table listener (users table)
const TableListener = socket.channel('realtime:public:users')

TableListener.on('INSERT', (change) => {
  console.log('INSERT on TableListener', change)
})
TableListener.on('UPDATE', (change) => {
  console.log('UPDATE on TableListener', change)
})
TableListener.on('DELETE', (change) => {
  console.log('DELETE on TableListener', change)
})

TableListener.subscribe()
  .receive('ok', () => console.log('TableListener connected '))
  .receive('error', () => console.log('Failed'))
  .receive('timeout', () => console.log('Waiting...'))
