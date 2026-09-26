/*
 VYRA Live Mode
 Uses Supabase Auth + Postgres + Storage.
 Add your project URL and publishable key to window.VYRA_SUPABASE in supabase-config.js.
 This file never contains a secret/service-role key.
*/
(function(){
  const cfg=window.VYRA_SUPABASE||{};
  if(!cfg.url||!cfg.key||cfg.url.includes('YOUR_')){window.VYRA_LIVE_READY=false;return;}
  if(!window.supabase?.createClient){console.warn('Supabase client missing');return;}
  const sb=window.supabase.createClient(cfg.url,cfg.key);
  window.vyraDb=sb; window.VYRA_LIVE_READY=true;

  const today=()=>new Date().toISOString().slice(0,10);
  const escLocal=(v)=>String(v??'').replace(/[&<>"]/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[m]));

  async function profile(){
    const {data:{user}}=await sb.auth.getUser(); if(!user) return null;
    const {data}=await sb.from('profiles').select('*').eq('id',user.id).single();
    return data||null;
  }
  async function studentRecord(){
    const p=await profile(); if(!p) return null;
    const {data}=await sb.from('students').select('*').eq('profile_id',p.id).maybeSingle(); return data;
  }
  async function liveSections(){
    const {data,error}=await sb.from('sections').select('*').order('created_at',{ascending:false});
    if(error) throw error;
    return data||[];
  }
  async function liveStudents(){
    const {data,error}=await sb.from('students').select('id,student_id,profile_id,profiles(full_name),placements(id,section_id,preceptor_id,ci_id,status,sections(id,department,section,building,floor))').order('created_at');
    if(error) throw error;
    return (data||[]).map(s=>({
      name:s.profiles?.full_name||'Student',
      id:s.student_id,
      dbId:s.id, profileId:s.profile_id,
      sectionId:s.placements?.[0]?.section_id||null,
      placementId:s.placements?.[0]?.id||null,
      preceptorId:s.placements?.[0]?.preceptor_id||null,
      ciId:s.placements?.[0]?.ci_id||null,
      placement:s.placements?.[0]?.sections||null,
      shift:'OFF',attendance:'OFF',progress:0,status:s.placements?.[0]?.status||'Active'
    }));
  }
  async function loadDashboard(){
    try{
      ciSections=await liveSections();
      students=await liveStudents();
      renderSections();renderSectionOptions();renderStudents();renderPlacements();renderAttendance();renderSchedule();renderReports();renderOverviewStudents();
      await loadAttendanceToday(); await loadVideos();
    }catch(e){console.error(e);toast('Live data could not be loaded. Check the database schema.');}
  }
  async function loadAttendanceToday(){
    const day=today();
    const {data,error}=await sb.from('attendance').select('*').eq('attendance_date',day);
    if(error)return;
    const map=Object.fromEntries((data||[]).map(a=>[a.student_id,a]));
    students.forEach(s=>{const a=map[s.dbId];if(a)s.attendance=a.status;});
    renderAttendance();renderStudents();renderReports();renderStudentPortal();
  }
  async function loadVideos(){
    const {data,error}=await sb.from('learning_videos').select('id,title,storage_path,uploader_id,created_at,section_id,profiles(full_name,role)').order('created_at',{ascending:false});
    if(error) return;
    learningVideos=[];
    for(const v of (data||[])){
      const {data:signed}=await sb.storage.from('learning-videos').createSignedUrl(v.storage_path,3600);
      learningVideos.push({id:v.id,title:v.title,url:signed?.signedUrl||'',role:v.profiles?.role||'Staff',name:v.profiles?.full_name||'VYRA',sectionId:v.section_id,storagePath:v.storage_path});
    }
    renderLearningVideos();
  }
  window.vyraLive={
    async signIn(email,password){
      const {data,error}=await sb.auth.signInWithPassword({email,password});
      if(error) throw error; return data.user;
    },
    async signUp({name,email,password,studentId,role,staffId,proofFile}){
      const {data,error}=await sb.auth.signUp({email,password,options:{data:{full_name:name}}});
      if(error) throw error;
      const uid=data.user?.id; if(!uid) throw new Error('Account creation did not return a user.');
      if(role==='Student'){
        const {error:e}=await sb.from('students').insert({profile_id:uid,student_id:studentId});
        if(e) throw e;
      }else{
        let verification_path=null;
        if(proofFile){
          verification_path=uid+'/'+Date.now()+'-'+proofFile.name.replace(/[^a-zA-Z0-9._-]/g,'_');
          const {error:e}=await sb.storage.from('verification-docs').upload(verification_path,proofFile,{upsert:false});
          if(e) throw e;
        }
        const {error:e}=await sb.from('role_requests').insert({user_id:uid,requested_role:role,staff_id:staffId,verification_path});
        if(e) throw e;
      }
      return data.user;
    },
    async signOut(){await sb.auth.signOut();},
    async createSection(v){
      const {data,error}=await sb.from('sections').insert({department:v.department,section:v.section,building:v.building,floor:v.floor||null,created_by:(await profile()).id}).select('*').single();
      if(error)throw error; return data;
    },
    async deleteSection(id){const {error}=await sb.from('sections').delete().eq('id',id);if(error)throw error;},
    async createStudent(v){
      const {data,error}=await sb.auth.admin; // intentionally unavailable in browser
      throw new Error('Student accounts are created through registration; an admin action is needed to create an account with a password.');
    },
    async checkIn(){
      const st=await studentRecord(); if(!st) throw new Error('Student profile not found.');
      const now=new Date().toISOString();
      const {data,error}=await sb.from('attendance').upsert({student_id:st.id,attendance_date:today(),status:'Present',check_in:now},{onConflict:'student_id,attendance_date'}).select().single();
      if(error)throw error; return data;
    },
    async checkOut(){
      const st=await studentRecord(); if(!st) throw new Error('Student profile not found.');
      const {data,error}=await sb.from('attendance').update({check_out:new Date().toISOString(),updated_at:new Date().toISOString()}).eq('student_id',st.id).eq('attendance_date',today()).select().single();
      if(error)throw error; return data;
    },
    async addVideo(title,file,sectionId){
      const p=await profile(); if(!p) throw new Error('Sign in first.');
      const path=p.id+'/'+Date.now()+'-'+file.name.replace(/[^a-zA-Z0-9._-]/g,'_');
      const {error:u}=await sb.storage.from('learning-videos').upload(path,file,{upsert:false,contentType:file.type});
      if(u)throw u;
      const {data,error}=await sb.from('learning_videos').insert({title,storage_path:path,uploader_id:p.id,section_id:sectionId||null}).select().single();
      if(error){await sb.storage.from('learning-videos').remove([path]);throw error;}
      return data;
    },
    async submitRequest(v){
      const st=await studentRecord(); if(!st) throw new Error('Student profile not found.');
      const {data,error}=await sb.from('requests').insert({student_id:st.id,request_type:v.type,request_date:v.date,details:v.detail,attachment_path:v.attachmentPath||null}).select().single();
      if(error)throw error;return data;
    },
    async submitEvaluations(v){
      const st=await studentRecord(); if(!st) throw new Error('Student profile not found.');
      const rows=[
        {student_id:st.id,evaluation_type:'department',section_id:v.unit||null,rating:Number(v.unitScore),comments:v.departmentComments||null},
        {student_id:st.id,evaluation_type:'preceptor',section_id:v.unit||null,preceptor_id:v.preceptorId||null,rating:Number(v.preceptorScore),comments:v.preceptorComments||null}
      ];
      const {data,error}=await sb.from('evaluations').insert(rows).select();
      if(error)throw error;return data;
    }
  };

  // Replace demo-only auth with real Supabase authentication.
  window.submitAuth=async function(){
    const name=document.getElementById('loginName').value.trim();
    const email=document.getElementById('email').value.trim().toLowerCase();
    const password=document.getElementById('password').value;
    if(!email||!password||!email.includes('@')){toast('Enter a valid email and password.');return;}
    try{
      if(authMode==='login'){
        const p=await vyraLive.signIn(email,password);const pr=await profile();
        if(!pr){toast('Account profile is not ready yet.');return;}
        currentRole=pr.role;currentDisplayName=pr.full_name;currentStudentId=(await studentRecord())?.student_id||'';
        closeLogin();enterWorkspace(currentDisplayName);await loadDashboard();toast('Signed in securely.');
        return;
      }
      if(!name){toast('Enter your full name.');return;}
      if(selectedRole==='Student'){
        const sid=document.getElementById('studentIdInput').value.trim();if(!sid){toast('Enter your student or training ID.');return;}
        await vyraLive.signUp({name,email,password,studentId:sid,role:selectedRole});
        toast('Account created. Check your email if confirmation is enabled.');
      }else{
        const staffId=document.getElementById('staffIdInput').value.trim(), proof=document.getElementById('proofInput').files[0];
        if(!staffId||!proof){toast('Work ID and verification document are required.');return;}
        await vyraLive.signUp({name,email,password,role:selectedRole,staffId,proofFile:proof});
        toast('Access request submitted. A supervisor must approve the staff role.');
      }
      closeLogin();
    }catch(e){console.error(e);toast(e.message||'Authentication failed.');}
  };

  window.signOut=async function(){await vyraLive.signOut();document.getElementById('workspace').classList.remove('show');document.getElementById('studentPortal').classList.remove('active');toast('Signed out.');};

  window.addLearningVideo=async function(){
    if(!['Preceptor','CI','Department Supervisor'].includes(currentRole)){toast('Only authorized training staff can upload videos.');return;}
    const title=document.getElementById('learningVideoTitle').value.trim(),file=document.getElementById('learningVideoFile').files[0];
    if(!title||!file){toast('Enter a video title and choose a video file.');return;}
    try{await vyraLive.addVideo(title,file);await loadVideos();document.getElementById('learningVideoTitle').value='';document.getElementById('learningVideoFile').value='';toast('Video uploaded to VYRA.');}
    catch(e){toast(e.message||'Video upload failed.');}
  };

  window.studentCheckIn=async function(){try{await vyraLive.checkIn();await loadAttendanceToday();toast('Check-in recorded.');}catch(e){toast(e.message||'Check-in failed.');}};
  window.studentCheckOut=async function(){try{await vyraLive.checkOut();await loadAttendanceToday();toast('Check-out recorded.');}catch(e){toast(e.message||'Check-out failed.');}};
  window.submitStudentRequest=async function(){
    const type=document.getElementById('studentRequestType').value,date=document.getElementById('studentRequestDate').value,detail=document.getElementById('studentRequestDetail').value.trim();
    if(!date||!detail){toast('Choose a date and enter the request details.');return;}
    try{await vyraLive.submitRequest({type,date,detail});studentOwnRequests.unshift({type,date,detail,status:'Pending'});renderStudentPortal();renderRequests();toast('Request submitted.');}
    catch(e){toast(e.message||'Request failed.');}
  };
  window.submitEvaluation=async function(){
    try{
      await vyraLive.submitEvaluations({
        unit:document.getElementById('evalUnit').value,
        unitScore:document.getElementById('evalUnitScore').value,
        departmentComments:document.getElementById('evalDepartmentComments').value.trim(),
        preceptorId:document.getElementById('evalPreceptorName').value||null,
        preceptorScore:document.getElementById('evalPreceptorScore').value,
        preceptorComments:document.getElementById('evalPreceptorComments').value.trim()
      });
      document.getElementById('evalDepartmentComments').value='';document.getElementById('evalPreceptorComments').value='';
      toast('Evaluation submitted securely. Only authorized management can view it.');
    }catch(e){toast(e.message||'Evaluation failed.');}
  };
  window.addSection=async function(){
    if(currentRole!=='CI'){toast('Only a CI can create sections.');return;}
    const department=document.getElementById('newDepartment').value.trim(),section=document.getElementById('newSection').value.trim(),building=document.getElementById('newBuilding').value.trim(),floor=document.getElementById('newFloor').value.trim();
    if(!department||!section||!building){toast('Enter department, section, and building.');return;}
    try{const d=await vyraLive.createSection({department,section,building,floor});ciSections.unshift(d);renderSections();renderSectionOptions();['newDepartment','newSection','newBuilding','newFloor'].forEach(k=>document.getElementById(k).value='');closeSectionForm();toast('Section and building saved.');}
    catch(e){toast(e.message||'Could not save section.');}
  };
  window.removeSection=async function(id){if(currentRole!=='CI')return;try{await vyraLive.deleteSection(id);ciSections=ciSections.filter(x=>x.id!==id);renderSections();renderSectionOptions();toast('Section removed.');}catch(e){toast(e.message||'Cannot remove this section.');}};

  sb.auth.onAuthStateChange(async(event,session)=>{
    if(session?.user){
      const pr=await profile();
      if(pr){currentRole=pr.role;currentDisplayName=pr.full_name;currentStudentId=(await studentRecord())?.student_id||currentStudentId;}
    }
  });
})();