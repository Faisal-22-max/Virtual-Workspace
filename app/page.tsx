import { supabase } from './lib/supabase'

export default async function Home() {
  const { data, error } = await supabase.from('workspaces').select('*')

  return (
    <div style={{ padding: '40px', color: 'white' }}>
      <h1>اختبار الاتصال بـ Supabase</h1>
      {error ? (
        <p style={{ color: 'red' }}>❌ خطأ: {error.message}</p>
      ) : (
        <p style={{ color: 'lightgreen' }}>
          ✅ الاتصال نجح! عدد الصفوف بجدول workspaces: {data?.length ?? 0}
        </p>
      )}
    </div>
  )
}