const { Socket } = require('@supabase/realtime-js')

const REALTIME_URL = process.env.REALTIME_URL || 'http://localhost:4000/socket'
const socket = new Socket(REALTIME_URL)

// Connect to the realtime server
socket.connect()

// Set up database listener
const DatabaseListener = socket
  .channel('realtime:*')
  .join()
  .receive('ok', () => console.log('DatabaseListener connected '))
  .receive('error', () => console.log('Failed'))
  .receive('timeout', () => console.log('Waiting...'))

// Set up schema listener (public schema)
const SchemaListener = socket
  .channel('realtime:public')
  .join()
  .receive('ok', () => console.log('SchemaListener connected '))
  .receive('error', () => console.log('Failed'))
  .receive('timeout', () => console.log('Waiting...'))

// Set up table listener (users table)
const TableListener = socket
  .channel('realtime:public:users')
  .join()
  .receive('ok', () => console.log('TableListener connected '))
  .receive('error', () => console.log('Failed'))
  .receive('timeout', () => console.log('Waiting...'))

/**
 * Log changes
 */
DatabaseListener.channel.on('*', (change) => {
  console.log('Change received on DatabaseListener', change)
})
SchemaListener.channel.on('*', (change) => {
  console.log('Change received on SchemaListener', change)
})
TableListener.channel.on('INSERT', (change) => {
  console.log('INSERT on TableListener', change)
})
TableListener.channel.on('UPDATE', (change) => {
  console.log('UPDATE on TableListener', change)
})
TableListener.channel.on('DELETE', (change) => {
  console.log('UPDATE on TableListener', change)
})

// Keep script alive
setInterval(function () {}, 10000)
