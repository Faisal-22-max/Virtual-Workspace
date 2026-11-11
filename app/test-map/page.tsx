'use client'

import { useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'

type Player = {
    id: string
    x: number
    y: number
    color: string
}

export default function TestMap() {
    const canvasRef = useRef<HTMLCanvasElement>(null)
    const [connectionStatus, setConnectionStatus] = useState('يتصل...')
    const [onlineCount, setOnlineCount] = useState(1)

    // معرف ولون وموقع عشوائي خاص بكل تبويب
    const myInfoRef = useRef<{ id: string; color: string }>({
        id: `user-${Math.floor(1000 + Math.random() * 9000)}`,
        color: `hsl(${Math.floor(Math.random() * 360)}, 75%, 60%)`,
    })

    const myPosRef = useRef({
        x: 300 + Math.floor(Math.random() * 200),
        y: 200 + Math.floor(Math.random() * 200),
    })

    const playersRef = useRef<Record<string, Player>>({})

    useEffect(() => {
        const { id: myId, color: myColor } = myInfoRef.current

        // نضيف أنفسنا كأول لاعب
        playersRef.current[myId] = {
            id: myId,
            x: myPosRef.current.x,
            y: myPosRef.current.y,
            color: myColor,
        }

        // 1. الاتصال بقناة البث في Supabase
        const channel = supabase.channel('test-map-room', {
            config: { broadcast: { self: false } },
        })

        // دالة تحديث عدد المتصلين
        const refreshCount = () => {
            setOnlineCount(Object.keys(playersRef.current).length)
        }

        // 2. الاستماع لتحديثات مواقع اللاعبين
        channel.on('broadcast', { event: 'position' }, ({ payload }) => {
            const player = payload as Player
            playersRef.current[player.id] = player
            refreshCount()
        })

        // 3. الاستماع لدخول لاعب جديد (Join): نسجله ونرد عليه بموقعنا ليرانا فوراً
        channel.on('broadcast', { event: 'join' }, ({ payload }) => {
            const player = payload as Player
            playersRef.current[player.id] = player
            refreshCount()

            // نرسل له موقعنا الحالي فوراً
            channel.send({
                type: 'broadcast',
                event: 'position',
                payload: {
                    id: myId,
                    x: myPosRef.current.x,
                    y: myPosRef.current.y,
                    color: myColor,
                },
            })
        })

        // 4. الاستماع لخروج لاعب
        channel.on('broadcast', { event: 'leave' }, ({ payload }) => {
            if (payload?.id && playersRef.current[payload.id]) {
                delete playersRef.current[payload.id]
                refreshCount()
            }
        })

        // 5. الاشتراك بالقناة وإعلان الانضمام فور الاتصال
        channel.subscribe((status) => {
            if (status === 'SUBSCRIBED') {
                setConnectionStatus('متصل ✅')
                // نعلن للجميع عن انضمامنا وموقعنا الأولي فوراً
                channel.send({
                    type: 'broadcast',
                    event: 'join',
                    payload: {
                        id: myId,
                        x: myPosRef.current.x,
                        y: myPosRef.current.y,
                        color: myColor,
                    },
                })
            } else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
                setConnectionStatus('❌ فشل الاتصال')
            }
        })

        // 6. التحكم بالأسهم أو أحرف WASD
        const speed = 2.0
        const keysPressed = new Set<string>()

        const handleKeyDown = (e: KeyboardEvent) => {
            if (['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'w', 's', 'a', 'd', 'W', 'S', 'A', 'D'].includes(e.key)) {
                keysPressed.add(e.key.toLowerCase())
            }
        }
        const handleKeyUp = (e: KeyboardEvent) => {
            keysPressed.delete(e.key.toLowerCase())
        }
        window.addEventListener('keydown', handleKeyDown)
        window.addEventListener('keyup', handleKeyUp)

        // بث الحركة بمعدل محدود (كل 50ms)
        let lastBroadcastTime = 0
        const broadcastInterval = 40

        const updateMovement = () => {
            const pos = myPosRef.current
            let dx = 0
            let dy = 0

            if (keysPressed.has('arrowup') || keysPressed.has('w')) dy -= 1
            if (keysPressed.has('arrowdown') || keysPressed.has('s')) dy += 1
            if (keysPressed.has('arrowleft') || keysPressed.has('a')) dx -= 1
            if (keysPressed.has('arrowright') || keysPressed.has('d')) dx += 1

            if (dx !== 0 || dy !== 0) {
                const length = Math.sqrt(dx * dx + dy * dy)
                pos.x = Math.max(25, Math.min(775, pos.x + (dx / length) * speed))
                pos.y = Math.max(25, Math.min(475, pos.y + (dy / length) * speed))

                playersRef.current[myId] = { id: myId, x: pos.x, y: pos.y, color: myColor }

                const now = Date.now()
                if (now - lastBroadcastTime > broadcastInterval) {
                    lastBroadcastTime = now
                    channel.send({
                        type: 'broadcast',
                        event: 'position',
                        payload: { id: myId, x: pos.x, y: pos.y, color: myColor },
                    })
                }
            }
        }

        // 7. دورة الرسم على الـ Canvas
        const canvas = canvasRef.current
        const ctx = canvas?.getContext('2d')
        let animationFrame: number

        const draw = () => {
            updateMovement()

            if (ctx && canvas) {
                // خلفية داكنة مع شبكة خفيفة
                ctx.fillStyle = '#0f172a'
                ctx.fillRect(0, 0, canvas.width, canvas.height)

                // رسم خطوط شبكة خفيفة كأرضية مكتب
                ctx.strokeStyle = '#1e293b'
                ctx.lineWidth = 1
                for (let x = 0; x < canvas.width; x += 40) {
                    ctx.beginPath()
                    ctx.moveTo(x, 0)
                    ctx.lineTo(x, canvas.height)
                    ctx.stroke()
                }
                for (let y = 0; y < canvas.height; y += 40) {
                    ctx.beginPath()
                    ctx.moveTo(0, y)
                    ctx.lineTo(canvas.width, y)
                    ctx.stroke()
                }

                // رسم اللاعبين
                Object.values(playersRef.current).forEach((p) => {
                    const isMe = p.id === myId

                    // حلقة إضاءة خارجية للاعب الحالي
                    if (isMe) {
                        ctx.beginPath()
                        ctx.arc(p.x, p.y, 25, 0, Math.PI * 2)
                        ctx.strokeStyle = '#38bdf8'
                        ctx.lineWidth = 2
                        ctx.stroke()
                    }

                    // دائرة اللاعب
                    ctx.beginPath()
                    ctx.arc(p.x, p.y, 20, 0, Math.PI * 2)
                    ctx.fillStyle = p.color
                    ctx.fill()
                    ctx.strokeStyle = '#ffffff'
                    ctx.lineWidth = 2
                    ctx.stroke()

                    // اسم اللاعب فوقه
                    ctx.fillStyle = '#f8fafc'
                    ctx.font = 'bold 12px sans-serif'
                    ctx.textAlign = 'center'
                    ctx.fillText(isMe ? `${p.id} (أنت)` : p.id, p.x, p.y - 28)
                })
            }
            animationFrame = requestAnimationFrame(draw)
        }
        draw()

        // 8. تنظيف عند الخروج
        return () => {
            window.removeEventListener('keydown', handleKeyDown)
            window.removeEventListener('keyup', handleKeyUp)
            cancelAnimationFrame(animationFrame)
            channel.send({
                type: 'broadcast',
                event: 'leave',
                payload: { id: myId },
            })
            supabase.removeChannel(channel)
        }
    }, [])

    const { id: myId, color: myColor } = myInfoRef.current

    return (
        <div style={{ padding: 24, color: '#f8fafc', background: '#020617', minHeight: '100vh', fontFamily: 'sans-serif' }}>
            <div style={{ marginBottom: 16 }}>
                <h1 style={{ margin: '0 0 8px 0', fontSize: 24, fontWeight: 'bold' }}>
                    🏢 تجربة التواجد والمزامنة الحية (Virtual Workspace Spike)
                </h1>
                <div style={{ display: 'flex', gap: 20, alignItems: 'center', fontSize: 14 }}>
                    <p style={{ margin: 0 }}>
                        الحالة: <b style={{ color: connectionStatus.includes('✅') ? '#4ade80' : '#f87171' }}>{connectionStatus}</b>
                    </p>
                    <p style={{ margin: 0 }}>
                        معرّفك: <span style={{ color: myColor, fontWeight: 'bold' }}>{myId}</span>
                    </p>
                    <p style={{ margin: 0 }}>
                        المتواجدون حالياً: <b style={{ color: '#38bdf8' }}>{onlineCount}</b>
                    </p>
                </div>
                <p style={{ margin: '8px 0 0 0', color: '#94a3b8', fontSize: 13 }}>
                    التحكم: استخدم <b>الأسهم ⬆️ ⬇️ ⬅️ ➡️</b> أو أحرف <b>WASD</b> للتحرك داخل المساحة.
                </p>
            </div>

            <canvas
                ref={canvasRef}
                width={800}
                height={500}
                style={{
                    border: '2px solid #334155',
                    borderRadius: 8,
                    display: 'block',
                    boxShadow: '0 10px 25px -5px rgba(0, 0, 0, 0.5)',
                }}
            />
        </div>
    )
}
